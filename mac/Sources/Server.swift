import Foundation
import Network

struct AddRequest: Decodable {
    var url: String
    var cookie: String?
    var referer: String?
    var filename: String?
    // Video pages (sent by the extension's video buttons)
    var kind: String?
    var mode: String?
    var quality: String?
    var audio: String?
    var title: String?
    var cookiesTxt: String?
}

struct HTTPRequest {
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var body = Data()

    /// nil until the whole request (headers + Content-Length body) has arrived.
    init?(_ data: Data) {
        guard let r = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<r.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        method = String(first[0])
        path = String(first[1])
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        guard data.distance(from: r.upperBound, to: data.endIndex) >= len else { return nil }
        body = data.subdata(in: r.upperBound..<data.index(r.upperBound, offsetBy: len))
    }
}

/// Tiny HTTP server on 127.0.0.1 that the Chrome extension posts links to.
///
/// Only requests carrying `X-DualDL: 1` are served. A web page can't add that
/// header to a cross-origin request without a CORS preflight, and preflights
/// are refused, so ordinary sites can't queue downloads behind your back.
@MainActor
final class LinkServer {
    static let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["DUALDL_PORT"] ?? "") ?? 51977  // override: tests

    var onState: ((Bool) -> Void)?
    var onContact: (() -> Void)?
    var onCookies: ((String) -> Void)?
    var wantCookies: () -> Bool = { false }
    var hasCookies: () -> Bool = { false }
    var onTurbo: ((Bool) -> Void)?
    private let onAdd: (AddRequest) -> Bool
    private var listener: NWListener?

    init(onAdd: @escaping (AddRequest) -> Bool) {
        self.onAdd = onAdd
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] st in
                MainActor.assumeIsolated {
                    switch st {
                    case .ready: self?.onState?(true)
                    case .failed, .cancelled: self?.onState?(false)
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in
                MainActor.assumeIsolated { self?.accept(c) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            onState?(false)
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            MainActor.assumeIsolated {
                var buf = acc
                if let d = data { buf.append(d) }
                if let req = HTTPRequest(buf) {
                    self?.reply(c, req)
                } else if done || err != nil || buf.count > 4_000_000 {
                    c.cancel()
                } else {
                    self?.read(c, buf)
                }
            }
        }
    }

    private func reply(_ c: NWConnection, _ req: HTTPRequest) {
        let (status, body) = route(req)
        var out = Data(("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n").utf8)
        out.append(Data(body.utf8))
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func route(_ req: HTTPRequest) -> (String, String) {
        let deny = ("403 Forbidden", #"{"ok":false}"#)
        guard req.method != "OPTIONS", req.headers["x-dualdl"] == "1" else { return deny }
        if let origin = req.headers["origin"], !origin.hasPrefix("chrome-extension://") { return deny }
        onContact?()
        let parts = req.path.split(separator: "?", maxSplits: 1)
        let path = parts.first.map(String.init) ?? req.path
        var query: [String: String] = [:]
        for kv in (parts.count > 1 ? parts[1] : "").split(separator: "&") {
            let p = kv.split(separator: "=", maxSplits: 1)
            if p.count == 2 { query[String(p[0])] = String(p[1]) }
        }
        switch (req.method, path) {
        case ("GET", "/ping"):
            // The extension reports whether Chrome took the Turbo proxy (or another extension holds it)
            if let applied = query["turbo"] {
                let t = TurboManager.shared
                t.chromeApplied = applied == "1"
                t.chromeBlocked = query["blocked"] == "1"
            }
            let turbo = TurboManager.shared
            return ("200 OK", #"{"ok":true,"app":"DualDL","wantCookies":"# + (wantCookies() ? "true" : "false")
                    + #","hasCookies":"# + (hasCookies() ? "true" : "false")
                    + #","turbo":"# + (turbo.enabled && turbo.running ? "true" : "false")
                    + #","turboPort":"# + String(TurboManager.port) + "}")
        case ("POST", "/turbo"):
            struct Body: Decodable { var on: Bool }
            guard let b = try? JSONDecoder().decode(Body.self, from: req.body) else {
                return ("400 Bad Request", #"{"ok":false}"#)
            }
            onTurbo?(b.on)
            return ("200 OK", #"{"ok":true}"#)
        case ("POST", "/cookies"):
            struct Body: Decodable { var cookiesTxt: String }
            guard wantCookies(), let b = try? JSONDecoder().decode(Body.self, from: req.body) else {
                return ("403 Forbidden", #"{"ok":false}"#)
            }
            onCookies?(b.cookiesTxt)
            return ("200 OK", #"{"ok":true}"#)
        case ("POST", "/add"):
            guard let a = try? JSONDecoder().decode(AddRequest.self, from: req.body), onAdd(a) else {
                return ("400 Bad Request", #"{"ok":false}"#)
            }
            return ("200 OK", #"{"ok":true}"#)
        default:
            return ("404 Not Found", #"{"ok":false}"#)
        }
    }
}
