// Renders the real views with stress data (long names, errors, three lines, every
// unzip and preview state) at several widths, light and dark. Built by run.sh.
import AppKit
import SwiftUI

let OUT = ProcessInfo.processInfo.environment["DUALDL_SNAP_OUT"] ?? FileManager.default.currentDirectoryPath
let MB: Int64 = 1 << 20
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
if let icon = ProcessInfo.processInfo.environment["DUALDL_ICON"].flatMap(NSImage.init(contentsOfFile:)) {
    app.applicationIconImage = icon        // the real app icon in the header, like the built app
}

@MainActor func item(_ name: String, _ st: DLState, size: Int64? = nil, done: Int64 = 0, video: String? = nil,
                     badge: String? = nil, speeds: [String: Double] = [:], recv: [String: Int64] = [:]) -> DownloadItem {
    var i = DownloadItem(url: "https://example.invalid/\(name)", name: name)
    i.state = st; i.size = size; i.done = done; i.speeds = speeds; i.received = recv; i.badge = badge
    if let v = video { i.kind = "video"; i.mode = v }
    if st == .completed { i.elapsed = 66; i.path = "/tmp/\(name)" }
    return i
}

@MainActor func fill(_ m: DownloadManager) {
    var a = item("Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film.mp4", .running, size: 255 * MB, done: 120 * MB,
                 video: "video", badge: "1080p", speeds: ["en0": 4.5e6, "en1": 4.6e6], recv: ["en0": 60 * MB, "en1": 60 * MB])
    var b = item("Holiday Videos -20260101T120000Z-1-002.zip", .running, size: 1700 * MB, done: 300 * MB,
                 speeds: ["en0": 0, "en1": 3.7e6], recv: ["en0": 100 * MB, "en1": 200 * MB]); b.down = ["en0"]
    var c = item("Video", .running, video: "video"); c.stage = "Reading the page on every line…"
    let d = item("ubuntu-26.04-desktop-arm64.iso", .paused, size: 6100 * MB, done: 2300 * MB)
    var e = item("Some video.mp4", .failed, video: "video"); e.error = "YouTube wants to check you're not a bot. Turn on Settings → Use my Chrome login (with Chrome open), or send the video from Chrome with the DualDL extension."
    var f = item("Holiday Videos -20260101T120000Z-1-001.zip", .completed, size: 1750 * MB, done: 1750 * MB, recv: ["en0": 900 * MB, "en1": 850 * MB])
    f.unzip = UnzipInfo(state: "running", done: 700 * MB, size: 1700 * MB, main: "/Users/x/Downloads/Holiday Videos")
    var g = item("Holiday Videos -20260101T120000Z-1-003.zip", .completed, size: 1200 * MB, done: 1200 * MB, recv: ["en0": 600 * MB, "en1": 600 * MB])
    g.unzip = UnzipInfo(state: "done", done: 1, size: 1, main: "/Users/x/Downloads/Holiday Videos", message: "Zip moved to Trash")
    var h = item("photos-backup.zip", .completed, size: 12000 * MB, done: 12000 * MB)
    h.unzip = UnzipInfo(state: "failed", message: "Not enough disk space: needs 12.4 GB, 3.1 GB free. Free some space and click Retry to try again later on.")
    var s = item("big.zip.001", .completed, size: 500 * MB, done: 500 * MB); s.unzip = UnzipInfo(state: "waiting", message: "Waiting for the other pieces")
    let i = item("Me at the zoo.mp3", .completed, size: 3 * MB, done: 3 * MB, video: "audio", badge: "MP3", recv: ["en1": 3 * MB])
    let j = item("queued-file.dmg", .queued)
    let k = item(String(repeating: "VeryLongFileNameWithoutAnySpaces", count: 6) + ".mov", .running, size: 900 * MB, done: 10 * MB,
                 speeds: ["en0": 1e6], recv: ["en0": 10 * MB])
    m.items = [a, b, c, d, e, f, g, h, s, i, j, k]
    _ = a; _ = b; _ = c; _ = e; _ = f; _ = g; _ = h; _ = s
    m.lines = [
        NetLine(iface: "en0", label: "Ethernet", ip: "192.168.1.20", ok: true, publicIP: "203.0.113.24", isp: "FiberNet Communications Ltd.", ms: 500, sameAs: ""),
        NetLine(iface: "en1", label: "WiFi", ip: "192.168.1.21", ok: true, publicIP: "198.51.100.7", isp: "City Broadband", ms: 500, sameAs: ""),
        NetLine(iface: "en7", label: "USB 10/100/1000 LAN", ip: "10.0.0.5", ok: false, publicIP: "", isp: "", ms: 0, sameAs: ""),
    ]
    m.labels = ["en0": "Ethernet", "en1": "WiFi", "en7": "USB 10/100/1000 LAN"]
    WiFiNames.shared.names = ["en1": "Home Wi-Fi"]
    m.serverRunning = true
    m.lastExtensionContact = Date()
    UserDefaults.standard.set(false, forKey: "turbo")
}

@MainActor func render<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat, dark: Bool, _ name: String) {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: v.frame(width: w, height: h).background(Color(nsColor: .windowBackgroundColor)))
    host.frame = NSRect(x: 0, y: 0, width: w, height: h)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(OUT)/\(name).png"))
}

MainActor.assumeIsolated {
    let m = DownloadManager.shared
    fill(m)
    let tools = ToolsManager.shared
    tools.ytdlp = ToolInfo(path: "/x/yt-dlp", version: "2026.08.19")
    tools.ffmpeg = ToolInfo(path: "/x/ffmpeg", version: "9.0.2")
    m.linesChecked = Date()
    for (w, h) in [(760.0, 900.0), (880.0, 900.0), (1200.0, 900.0)] {
        for dark in [true, false] {
            render(ContentView().environmentObject(m), w, h, dark: dark, "main-\(Int(w))-\(dark ? "dark" : "light")")
        }
    }
    let p = VideoPreview(title: "A very long video title that goes on and on to check wrapping in the card — Official Music Video (4K Remaster) [HD]",
                         uploader: "Some Channel With A Long Name", duration: 3725, thumbnail: "", site: "Youtube",
                         qualities: [2160, 1440, 1080, 720, 480, 360].map { VideoQuality(height: $0, size: Int64($0) * 300_000, fps: 60) },
                         mp3Size: 9 * MB, audioSize: 8 * MB)
    let states: [(String, PreviewState)] = [("loading", .loading("u")), ("ready", .ready("u", p)),
        ("failed", .failed("u", "YouTube wants to check you're not a bot. Turn on Settings → Use my Chrome login (with Chrome open), or send the video from Chrome with the DualDL extension."))]
    for (n, st) in states {
        for mode in ["video", "audio"] {
            render(VideoCard(state: st, mode: .constant(mode), quality: .constant("best"), audio: .constant("mp3"), tools: tools).padding(20),
                   720, 150, dark: true, "card-\(n)-\(mode)")
        }
    }
    tools.ytdlp = ToolInfo()
    render(VideoCard(state: .idle, mode: .constant("video"), quality: .constant("best"), audio: .constant("mp3"), tools: tools).padding(20),
           720, 170, dark: false, "card-notools")
    tools.ytdlp = ToolInfo(path: "/x/yt-dlp", version: "2026.08.19")
    render(SettingsView().environmentObject(m), 560, 540, dark: true, "settings-dark")
    exit(0)
}
