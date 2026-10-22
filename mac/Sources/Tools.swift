import Foundation

struct ToolInfo: Equatable {
    var path: String?
    var version: String?
    var installed: Bool { path != nil }
}

/// yt-dlp, Deno and ffmpeg: what's installed, and installing/updating them (tools.py).
@MainActor
final class ToolsManager: ObservableObject {
    static let shared = ToolsManager()

    @Published var ytdlp = ToolInfo()
    @Published var deno = ToolInfo()
    @Published var ffmpeg = ToolInfo()
    @Published var busy = false
    @Published var progress: Double?
    @Published var message: String?
    @Published var checked = false

    private let defaults = UserDefaults.standard
    var autoUpdate: Bool { defaults.object(forKey: "autoUpdateTools") as? Bool ?? true }

    /// Video downloads need yt-dlp; ffmpeg is needed to join streams and make MP3.
    var ready: Bool { ytdlp.installed && ffmpeg.installed }

    init() {
        refresh()
    }

    func refresh() {
        Engine.run("tools", ["--status"], onEvent: { [weak self] e in self?.apply(e) },
                   onExit: { [weak self] _, _ in
                       self?.checked = true
                       self?.updateIfDue()
                   })
    }

    func install() {
        guard !busy else { return }
        busy = true
        progress = nil
        message = "Checking for the latest versions…"
        Engine.run("tools", ["--install"], onEvent: { [weak self] e in self?.apply(e) },
                   onExit: { [weak self] code, tail in
                       guard let self else { return }
                       self.busy = false
                       self.progress = nil
                       if code == 0 {
                           self.message = "Up to date"
                           self.defaults.set(Date(), forKey: "toolsUpdated")
                       } else if self.message == nil || self.message?.hasPrefix("Downloading") == true {
                           self.message = tail.isEmpty ? "Install failed" : tail
                       }
                   })
    }

    /// YouTube changes often and old yt-dlp versions stop working, so check weekly.
    private func updateIfDue() {
        guard autoUpdate, ytdlp.installed else { return }
        let last = defaults.object(forKey: "toolsUpdated") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 7 * 24 * 3600 { install() }
    }

    private func apply(_ e: [String: Any]) {
        switch e["event"] as? String {
        case "status":
            let t = e["tools"] as? [String: [String: Any]] ?? [:]
            func info(_ k: String) -> ToolInfo { ToolInfo(path: t[k]?["path"] as? String, version: t[k]?["version"] as? String) }
            ytdlp = info("yt-dlp")
            deno = info("deno")
            ffmpeg = info("ffmpeg")
        case "progress":
            let done = (e["done"] as? NSNumber)?.doubleValue ?? 0
            let size = (e["size"] as? NSNumber)?.doubleValue ?? 0
            progress = size > 0 ? done / size : nil
            message = "Downloading \(e["tool"] as? String ?? "")…"
        case "log":
            message = e["message"] as? String
        case "error":
            message = e["message"] as? String
        default:
            break
        }
    }
}
