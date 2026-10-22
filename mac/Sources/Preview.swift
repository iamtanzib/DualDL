import Foundation

/// Sites yt-dlp handles that people usually paste. Any other link can still be
/// sent through the video downloader with the film button.
func isVideoURL(_ s: String) -> Bool {
    guard let host = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
        return false
    }
    let sites = ["youtube.com", "youtu.be", "vimeo.com", "facebook.com", "fb.watch", "instagram.com",
                 "tiktok.com", "x.com", "twitter.com", "dailymotion.com", "twitch.tv", "reddit.com",
                 "soundcloud.com", "bilibili.com", "bandcamp.com", "streamable.com", "ted.com"]
    return sites.contains { host == $0 || host.hasSuffix("." + $0) }
}

struct VideoQuality: Hashable {
    var height: Int
    var size: Int64
    var fps: Double?
}

struct VideoPreview: Equatable {
    var title: String
    var uploader: String
    var duration: Double
    var thumbnail: String
    var site: String
    var qualities: [VideoQuality]
    var mp3Size: Int64
    var audioSize: Int64
}

enum PreviewState: Equatable {
    case idle
    case loading(String)
    case ready(String, VideoPreview)
    case failed(String, String)

    var url: String? {
        switch self {
        case .idle: return nil
        case .loading(let u), .ready(let u, _), .failed(let u, _): return u
        }
    }
}

/// Reads title, thumbnail and the available qualities for the link being typed.
/// The result is cached by video.py, so the download that follows doesn't read the page again.
@MainActor
final class VideoPreviewer: ObservableObject {
    @Published var state: PreviewState = .idle
    private var process: Process?
    private var pending: DispatchWorkItem?

    func load(_ raw: String, lines: [String]) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if state.url == url { return }
        pending?.cancel()
        process?.terminate()
        state = .loading(url)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start(url, lines) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)    // wait for typing to stop
    }

    /// Shown after "Use My Chrome Login" until the extension hands the login over.
    func waitForLogin(_ url: String) {
        pending?.cancel()
        process?.terminate()
        state = .failed(url, "Waiting for your login from Chrome… keep Chrome open (up to a minute).")
    }

    func clear() {
        pending?.cancel()
        process?.terminate()
        process = nil
        state = .idle
    }

    private func start(_ url: String, _ lines: [String]) {
        var args = ["--preview", url]
        if !lines.isEmpty { args += ["-i", lines.joined(separator: ",")] }
        let login = DownloadManager.shared.tempLoginFile()
        if let login { args += ["--cookies", login] }
        process = Engine.run("video", args, onEvent: { [weak self] e in
            guard let self, self.state.url == url else { return }
            switch e["event"] as? String {
            case "preview":
                let qs = (e["qualities"] as? [[String: Any]] ?? []).map {
                    VideoQuality(height: ($0["height"] as? NSNumber)?.intValue ?? 0,
                                 size: ($0["size"] as? NSNumber)?.int64Value ?? 0,
                                 fps: ($0["fps"] as? NSNumber)?.doubleValue)
                }
                self.state = .ready(url, VideoPreview(
                    title: e["title"] as? String ?? "Video",
                    uploader: e["uploader"] as? String ?? "",
                    duration: (e["duration"] as? NSNumber)?.doubleValue ?? 0,
                    thumbnail: e["thumbnail"] as? String ?? "",
                    site: e["site"] as? String ?? "",
                    qualities: qs,
                    mp3Size: (e["mp3_size"] as? NSNumber)?.int64Value ?? 0,
                    audioSize: (e["audio_size"] as? NSNumber)?.int64Value ?? 0))
            case "error":
                self.state = .failed(url, e["message"] as? String ?? "Couldn't read this video")
            default:
                break
            }
        }, onExit: { [weak self] _, tail in
            if let login { try? FileManager.default.removeItem(atPath: login) }
            guard let self, case .loading(let u) = self.state, u == url else { return }
            self.state = .failed(url, tail.isEmpty ? "Couldn't read this video" : tail)
        })
    }
}
