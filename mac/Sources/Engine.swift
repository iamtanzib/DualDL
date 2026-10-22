import Foundation

/// Runs one of the bundled Python scripts and hands back its JSON-lines output.
@MainActor
enum Engine {
    static func path(_ script: String) -> String { Bundle.main.path(forResource: script, ofType: "py") ?? "" }

    private final class Buffer {
        var out = Data()
        var err = Data()
    }

    /// Starts `python3 <script>.py args…`. `onEvent` gets every JSON object the script
    /// prints; `onExit` gets the exit code and the last stderr line. Both run on the main actor.
    @discardableResult
    static func run(_ script: String, _ args: [String], env: [String: String] = [:],
                    qos: QualityOfService = .utility,
                    onEvent: @escaping @MainActor ([String: Any]) -> Void,
                    onExit: @escaping @MainActor (Int32, String) -> Void) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-u", path(script)] + args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        p.qualityOfService = qos           // .utility by default: never compete with the apps you're using
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let buf = Buffer()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    buf.out.append(d)
                    while let nl = buf.out.firstIndex(of: 0x0A) {
                        let line = Data(buf.out[buf.out.startIndex..<nl])
                        buf.out.removeSubrange(buf.out.startIndex...nl)
                        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { onEvent(obj) }
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { buf.err.append(d) } }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {     // let the last lines land first
                MainActor.assumeIsolated {
                    let tail = String(data: buf.err, encoding: .utf8)?
                        .split(separator: "\n").last.map(String.init) ?? ""
                    onExit(code, tail)
                }
            }
        }
        do {
            try p.run()
            return p
        } catch {
            onExit(-1, error.localizedDescription)
            return nil
        }
    }
}
