import AppKit
import Foundation
import Network
import UniformTypeIdentifiers
import UserNotifications

enum DLState: String, Codable {
    case queued, running, paused, completed, failed
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: String
    var name: String
    var nameFixed = false          // name came from the browser or the server, reuse it on resume
    var referer: String?
    var folder: String?            // where the user chose to save it
    var path: String?
    var size: Int64?
    var done: Int64 = 0
    var state: DLState = .queued
    var error: String?
    var added = Date()
    var finished: Date?
    var elapsed: Double?
    var received: [String: Int64] = [:]
    // Video downloads (yt-dlp)
    var kind: String?              // "video" or nil for a plain file
    var mode: String?              // "video" | "audio"
    var quality: String?           // "best", "compatible" or a height like "1080"
    var audio: String?             // "mp3" | "original"
    var thumbnail: String?
    var badge: String?             // "1080p", "MP3"…
    var work: String?              // video.py's temp folder, removed on cancel
    var unzip: UnzipInfo?
    var group: String?             // the Drive folder this file came from
    var skipExisting: Bool?        // folder files: done at once if already here in full
    var retries = 0                // automatic retries since the download last made progress
    var retryAt: Date?             // when the next automatic retry happens
    var retryBase: Int64 = 0       // bytes done at the last failure
    // Live only, not saved
    var speeds: [String: Double] = [:]
    var down: [String] = []        // lines that keep failing right now
    var log: String?
    var stage: String?             // "Joining video and audio…"

    var isVideo: Bool { kind == "video" }
    var isConvert: Bool { kind == "convert" }

    enum CodingKeys: String, CodingKey {
        case id, url, name, nameFixed, referer, folder, path, size, done, state, error, added, finished,
             elapsed, received, kind, mode, quality, audio, thumbnail, badge, work, unzip, group,
             skipExisting, retries, retryAt, retryBase
    }
}

extension DownloadItem {
    /// Reads a saved item field by field: anything missing (an older list, a newer field)
    /// takes its default, so an update never makes the saved list unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
        self.init(url: try c.decode(String.self, forKey: .url), name: opt(String.self, .name) ?? "download")
        id = opt(UUID.self, .id) ?? UUID()
        nameFixed = opt(Bool.self, .nameFixed) ?? false
        referer = opt(String.self, .referer)
        folder = opt(String.self, .folder)
        path = opt(String.self, .path)
        size = opt(Int64.self, .size)
        done = opt(Int64.self, .done) ?? 0
        state = opt(DLState.self, .state) ?? .paused
        error = opt(String.self, .error)
        added = opt(Date.self, .added) ?? Date()
        finished = opt(Date.self, .finished)
        elapsed = opt(Double.self, .elapsed)
        received = opt([String: Int64].self, .received) ?? [:]
        kind = opt(String.self, .kind)
        mode = opt(String.self, .mode)
        quality = opt(String.self, .quality)
        audio = opt(String.self, .audio)
        thumbnail = opt(String.self, .thumbnail)
        badge = opt(String.self, .badge)
        work = opt(String.self, .work)
        unzip = opt(UnzipInfo.self, .unzip)
        group = opt(String.self, .group)
        skipExisting = opt(Bool.self, .skipExisting)
        retries = opt(Int.self, .retries) ?? 0
        retryAt = opt(Date.self, .retryAt)
        retryBase = opt(Int64.self, .retryBase) ?? 0
    }
}

/// One saved item that couldn't be read is skipped instead of losing the whole list.
private struct LossyItem: Decodable {
    let item: DownloadItem?
    init(from decoder: Decoder) throws { item = try? DownloadItem(from: decoder) }
}

struct UnzipInfo: Codable, Equatable {
    var state: String              // queued, running, done, waiting, failed
    var done: Int64 = 0
    var size: Int64 = 0
    var main: String?              // the folder the files went into
    var message: String?
}

struct VideoRequest {
    var mode = "video"
    var quality = "best"
    var audio = "mp3"
    var cookiesTxt: String?        // Netscape cookies from the Chrome extension
    var title: String?
    var thumbnail: String?
}

/// One network interface plus what `dualdl.py --check-lines` found out through it.
struct NetLine: Codable, Identifiable, Hashable {
    var iface: String
    var label: String
    var ip: String
    var ok: Bool?
    var publicIP: String?
    var isp: String?
    var ms: Int?
    var sameAs: String?            // iface with the same public IP = same internet connection
    var id: String { iface }

    /// Online and not a duplicate of another line's connection.
    var usable: Bool { ok == true && (sameAs ?? "").isEmpty }

    enum CodingKeys: String, CodingKey {
        case iface, label, ip, ok, isp, ms
        case publicIP = "public_ip", sameAs = "same_as"
    }
}

enum LineHealth: Equatable {
    case checking, separate(Int), sameConnection, single, offline
}

private struct PendingAdd {
    var url: String
    var cookie: String?
    var referer: String?
    var filename: String?
    var video: VideoRequest?
    var folderName: String?                 // a Drive folder, already listed
    var folderFiles: [[String: String]]?
}

/// Google Drive folder links (and the local stand-in tests use).
func isDriveFolderURL(_ s: String) -> Bool {
    if let base = ProcessInfo.processInfo.environment["DUALDL_DRIVE_BASE"], s.hasPrefix(base), s.contains("/folders/") {
        return true
    }
    return s.range(of: #"(drive|docs)\.google\.com/(drive/(u/\d+/)?folders/|embeddedfolderview|folderview)"#,
                   options: .regularExpression) != nil
}

/// Owns the download list and runs one dualdl.py process per active download.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var items: [DownloadItem] = []
    @Published var lines: [NetLine] = []
    @Published var labels: [String: String] = [:]
    @Published var serverRunning = false
    @Published var lastExtensionContact: Date?
    @Published var pendingLink: String?
    @Published var checkingLines = false
    @Published var linesChecked: Date?
    /// Video-site login handed over by the Chrome extension ("Use my Chrome login"). Memory only.
    @Published private(set) var chromeLoginAt: Date?
    private var chromeLogin: String?

    /// Set by the main window so the Dock icon can bring it back after it was closed.
    var openMainWindow: (() -> Void)?

    private final class Run {
        let process: Process
        var buffer = Data()
        var stderr = Data()
        var userStopped = false
        var cleanup: [String]?         // set by cancel: partial files/folders to remove once the engine exits
        init(_ p: Process) { process = p }
    }

    private var runs: [UUID: Run] = [:]
    private var cookies: [UUID: String] = [:]     // in memory only, never written to disk
    private var cookieFiles: [UUID: String] = [:] // video cookies for yt-dlp: 0600 temp files, deleted after
    private var listingFolders: Set<String> = []
    private var retryTimer: Timer?
    /// Automatic retry delays (seconds): 1, 3, 10, 30, 60 minutes. Tests shorten them.
    private let retryDelays: [Double] = (ProcessInfo.processInfo.environment["DUALDL_RETRY_DELAYS"] ?? "60,180,600,1800,3600")
        .split(separator: ",").compactMap { Double($0) }
    private var unzipQueue: [UUID] = []
    private var unzipRun: (id: UUID, process: Process)?
    private var server: LinkServer?
    private var lineTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var recheck: DispatchWorkItem?
    private var askQueue: [PendingAdd] = []
    private var asking = false
    private var activity: NSObjectProtocol?

    private let defaults = UserDefaults.standard
    var folder: String { defaults.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads" }
    var connections: Int { max(1, defaults.object(forKey: "connections") as? Int ?? 4) }
    var maxConcurrent: Int { max(1, defaults.object(forKey: "maxConcurrent") as? Int ?? 1) }
    var notify: Bool { defaults.object(forKey: "notify") as? Bool ?? true }
    var askLocation: Bool { defaults.object(forKey: "askLocation") as? Bool ?? true }
    var keepAwake: Bool { defaults.object(forKey: "keepAwake") as? Bool ?? true }
    var autoUnzip: Bool { defaults.object(forKey: "autoUnzip") as? Bool ?? true }
    var compatVideos: Bool { defaults.object(forKey: "compatVideos") as? Bool ?? true }
    var trashZips: Bool { defaults.object(forKey: "trashZips") as? Bool ?? false }
    var speedLimit: Double {
        (defaults.object(forKey: "limitOn") as? Bool ?? false) ? defaults.object(forKey: "limitMB") as? Double ?? 5 : 0
    }

    private var enginePath: String { Engine.path("dualdl") }
    private var cookieDir: URL {
        Self.home(.cachesDirectory).appendingPathComponent("cookies")
    }

    /// ~/Library/<Application Support|Caches>/DualDL, or $DUALDL_HOME so tests never touch the real list.
    static func home(_ dir: FileManager.SearchPathDirectory) -> URL {
        if let h = ProcessInfo.processInfo.environment["DUALDL_HOME"] {
            return URL(fileURLWithPath: h).appendingPathComponent(dir == .cachesDirectory ? "Caches" : "Support")
        }
        return FileManager.default.urls(for: dir, in: .userDomainMask)[0].appendingPathComponent("DualDL")
    }
    private var storeURL: URL {
        let dir = Self.home(.applicationSupportDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }

    init() {
        try? FileManager.default.removeItem(at: cookieDir)     // leftovers from a crash
        load()
        checkLines()
        // Re-check every 5 minutes and shortly after any network change (Wi-Fi joins
        // another network, a cable is pulled, an ISP goes down).
        lineTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLines() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WiFiNames.shared.refresh()
                    self?.scheduleLineCheck()
                }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        pump()
        for item in items.reversed() where item.unzip?.state == "queued" { unzipQueue.append(item.id) }
        pumpUnzip()
        retryTimer = Timer.scheduledTimer(withTimeInterval: min(15, (retryDelays.first ?? 15) / 2), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryDue() }
        }
    }

    /// Failed downloads that are worth another go resume on their own when their time comes.
    private func retryDue() {
        let now = Date()
        for item in items where item.state == .failed && (item.retryAt ?? .distantFuture) <= now {
            if let i = index(item.id) { items[i].retryAt = nil }
            resume(item.id, automatic: true)
        }
    }

    // MARK: - Derived values

    var totalSpeed: Double {
        items.filter { $0.state == .running }.reduce(0) { $0 + $1.speeds.values.reduce(0, +) }
    }

    func speed(for iface: String) -> Double {
        items.reduce(0) { $0 + ($1.state == .running ? $1.speeds[iface] ?? 0 : 0) }
    }

    var activeCount: Int { items.filter { $0.state == .running || $0.state == .queued }.count }

    var canPauseAll: Bool { items.contains { $0.state == .running || $0.state == .queued } }
    var canResumeAll: Bool { items.contains { $0.state == .paused || $0.state == .failed } }

    var health: LineHealth {
        if linesChecked == nil { return .checking }
        let online = lines.filter { $0.ok == true }
        if online.isEmpty { return .offline }
        if lines.contains(where: { !($0.sameAs ?? "").isEmpty }) { return .sameConnection }
        return online.count == 1 ? .single : .separate(online.count)
    }

    /// Different ISP names (not just different connections from one ISP).
    var distinctISPs: Bool {
        let names = lines.filter(\.usable).compactMap { $0.isp?.lowercased() }.filter { !$0.isEmpty }
        return Set(names).count == names.count && names.count > 1
    }

    /// Interfaces in the order the header shows them (wired first).
    func ordered(_ ifaces: [String]) -> [String] {
        let order = lines.map(\.iface)
        return ifaces.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
    }

    func label(_ iface: String) -> String { labels[iface] ?? iface }

    // MARK: - Adding

    /// Queues a link. With "ask where to save" on, a folder picker comes first and
    /// nothing is downloaded unless the user picks a folder.
    @discardableResult
    func add(url raw: String, cookie: String? = nil, referer: String? = nil, filename: String? = nil,
             video: VideoRequest? = nil) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else { return false }
        // A new link for a file that's already part-way here (signed links expire after a few
        // minutes, so the site hands out a new one): carry on with it instead of starting over.
        if video == nil, let i = items.firstIndex(where: { sameFile($0, u, filename) }) {
            items[i].url = s
            if let c = cookie, !c.isEmpty { cookies[items[i].id] = c }
            if let r = referer, !r.isEmpty { items[i].referer = r }
            if items[i].state == .failed || items[i].state == .paused { resume(items[i].id) } else { save() }
            return true
        }
        // Same link twice is fine as video and as MP3, not as two identical downloads
        if items.contains(where: { $0.url == s && $0.mode == video?.mode && ($0.state == .queued || $0.state == .running) })
            || askQueue.contains(where: { $0.url == s && $0.video?.mode == video?.mode }) { return true }
        let req = PendingAdd(url: s, cookie: cookie, referer: referer, filename: filename, video: video)
        if video == nil, isDriveFolderURL(s) {
            listFolder(req)
            return true
        }
        if askLocation {
            askQueue.append(req)
            askNext()
        } else {
            create(req, folder: folder)
        }
        return true
    }

    /// The same file behind another link: an unfinished plain download from the same host and
    /// path where only the query differs, and either both links are signed (the query is just
    /// the signature) or the file name matches (so page.php?id=1 and ?id=2 stay apart).
    private func sameFile(_ item: DownloadItem, _ u: URL, _ filename: String?) -> Bool {
        guard item.kind == nil, item.state != .completed, item.path != nil, u.path.count > 1,
              let old = URL(string: item.url), old.host == u.host, old.path == u.path else { return false }
        func signed(_ x: URL) -> Bool { x.query?.lowercased().contains("signature=") == true }
        let name = filename.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent } ?? u.lastPathComponent
        return (signed(old) && signed(u)) || name == item.name
    }

    /// A Drive folder link: read the folder's file list first, then ask where to save it once.
    private func listFolder(_ req: PendingAdd) {
        guard !listingFolders.contains(req.url) else { return }
        listingFolders.insert(req.url)
        var env: [String: String] = [:]
        if let c = req.cookie, !c.isEmpty { env["DUALDL_COOKIE"] = c }
        var answered = false
        Engine.run("dualdl", ["--json", "--list-folder", req.url], env: env, onEvent: { [weak self] e in
            guard let self else { return }
            switch e["event"] as? String {
            case "folder":
                answered = true
                let name = (e["name"] as? String).map { $0.replacingOccurrences(of: "/", with: "_") } ?? "Drive folder"
                let files = (e["files"] as? [[String: Any]] ?? []).map { f in
                    f.compactMapValues { $0 as? String }
                }
                if files.isEmpty {
                    self.failedNote(req.url, "Google Drive folder", "This folder is empty (or only has Google Docs, which can't be downloaded as files).")
                    return
                }
                var r = req
                r.folderName = name
                r.folderFiles = files
                if self.askLocation {
                    self.askQueue.append(r)
                    self.askNext()
                } else {
                    self.createFolder(r, base: self.folder)
                }
            case "error":
                answered = true
                self.failedNote(req.url, "Google Drive folder", e["message"] as? String ?? "Couldn't read the folder")
            default:
                break
            }
        }, onExit: { [weak self] _, tail in
            self?.listingFolders.remove(req.url)
            if !answered { self?.failedNote(req.url, "Google Drive folder", tail.isEmpty ? "Couldn't read the folder" : tail) }
        })
    }

    /// A row that only explains why something couldn't start.
    private func failedNote(_ url: String, _ name: String, _ message: String) {
        var item = DownloadItem(url: url, name: name)
        item.state = .failed
        item.error = message
        items.insert(item, at: 0)
        save()
    }

    /// One download per file, saved as <base>/<folder name>/<subfolders>/<file>.
    private func createFolder(_ req: PendingAdd, base: String) {
        guard let name = req.folderName, let files = req.folderFiles else { return }
        let root = (base as NSString).appendingPathComponent(name)
        for f in files.reversed() {
            guard let id = f["id"], let fileName = f["name"] else { continue }
            let link = f["url"] ?? "https://drive.google.com/file/d/\(id)/view"
            if items.contains(where: { $0.url == link && ($0.state == .queued || $0.state == .running) }) { continue }
            var item = DownloadItem(url: link, name: fileName)
            item.nameFixed = true
            item.folder = (root as NSString).appendingPathComponent(f["path"] ?? "")
            item.group = name
            item.skipExisting = true
            if let c = req.cookie, !c.isEmpty { cookies[item.id] = c }
            items.insert(item, at: 0)
        }
        save()
        pump()
    }

    private func create(_ req: PendingAdd, folder: String) {
        guard let u = URL(string: req.url) else { return }
        var item = DownloadItem(url: req.url, name: placeholderName(u, req.filename))
        item.referer = req.referer?.isEmpty == false ? req.referer : nil
        item.nameFixed = req.filename?.isEmpty == false
        item.folder = folder
        if let c = req.cookie, !c.isEmpty { cookies[item.id] = c }
        if let v = req.video {
            item.kind = "video"
            item.mode = v.mode
            item.quality = v.quality
            item.audio = v.audio
            item.thumbnail = v.thumbnail
            item.nameFixed = false
            item.name = (v.title ?? "Video") + (v.mode == "audio" ? (v.audio == "mp3" ? ".mp3" : ".m4a") : ".mp4")
            if let txt = v.cookiesTxt, !txt.isEmpty { writeCookieFile(item.id, txt) }
        }
        items.insert(item, at: 0)
        save()
        pump()
    }

    /// One folder picker at a time; links that arrive meanwhile wait their turn.
    private func askNext() {
        guard !asking, !askQueue.isEmpty else { return }
        asking = true
        let req = askQueue.removeFirst()
        let name = req.folderName.map { "the folder “\($0)” (\(req.folderFiles?.count ?? 0) files)" }
            ?? req.video?.title ?? URL(string: req.url).map { placeholderName($0, req.filename) } ?? "this file"

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Where should DualDL save “\(name)”?"
        panel.directoryURL = URL(fileURLWithPath: folder)
        let remember = NSButton(checkboxWithTitle: "Always save here and stop asking", target: nil, action: nil)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        remember.sizeToFit()
        remember.setFrameOrigin(NSPoint(x: (340 - remember.frame.width) / 2, y: 11))
        box.addSubview(remember)
        panel.accessoryView = box
        panel.isAccessoryViewDisclosed = true

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] resp in
            MainActor.assumeIsolated {
                guard let self else { return }
                if resp == .OK, let dir = panel.url?.path {
                    self.defaults.set(dir, forKey: "folder")       // next picker opens here
                    if remember.state == .on { self.defaults.set(false, forKey: "askLocation") }
                    if req.folderFiles != nil { self.createFolder(req, base: dir) } else { self.create(req, folder: dir) }
                }
                self.asking = false
                self.askNext()
            }
        }
    }

    private func placeholderName(_ u: URL, _ filename: String?) -> String {
        if let f = filename, !f.isEmpty { return (f as NSString).lastPathComponent }
        if u.host?.hasSuffix("google.com") == true { return "Google Drive file" }
        let last = u.lastPathComponent
        if last.isEmpty || last == "/" { return u.host ?? "download" }
        return last.removingPercentEncoding ?? last
    }

    func handleOpenURL(_ u: URL) {
        // dualdl://add?url=… only fills the link box; the user still presses Download.
        if u.scheme == "dualdl", u.host == "add",
           let c = URLComponents(url: u, resolvingAgainstBaseURL: false),
           let link = c.queryItems?.first(where: { $0.name == "url" })?.value {
            pendingLink = link
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Queue

    func pump() {
        var running = runs.count
        for item in items.reversed() where item.state == .queued && runs[item.id] == nil {
            if running >= maxConcurrent { break }
            start(item.id)
            running += 1
        }
        updateBadge()
        updateActivity()
    }

    /// While anything downloads: no App Nap, and (if enabled) no idle sleep.
    /// The display may still sleep. Released as soon as the last download stops.
    private func updateActivity() {
        let busy = !runs.isEmpty || unzipRun != nil
        if busy, activity == nil {
            let opts: ProcessInfo.ActivityOptions = keepAwake ? .userInitiated : .userInitiatedAllowingIdleSystemSleep
            activity = ProcessInfo.processInfo.beginActivity(options: opts, reason: "Downloading files")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func start(_ id: UUID) {
        guard let i = index(id) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let dest = items[i].path.map { ($0 as NSString).deletingLastPathComponent } ?? items[i].folder ?? folder
        let item = items[i]
        var args = ["-u", Engine.path(item.isVideo ? "video" : "dualdl"), "--json", "-o", dest,
                    "-n", String(connections)]
        if item.isConvert { args = ["-u", Engine.path("video"), "--json", "--convert", item.url] }
        // Only lines that are online and not a second path to the same connection
        let usable = lines.filter(\.usable).map(\.iface)
        if !usable.isEmpty { args += ["-i", usable.joined(separator: ",")] }
        if speedLimit > 0 { args += ["--limit", String(speedLimit)] }
        if item.isConvert {
            // nothing else: a local file, no lines or cookies involved
        } else if item.isVideo {
            args += ["--mode", item.mode ?? "video", "--quality", item.quality ?? "best", "--audio", item.audio ?? "mp3"]
            if !compatVideos { args.append("--keep-codec") }
            if cookieFiles[id] == nil, let txt = loginCookies { writeCookieFile(id, txt) }
            if let c = cookieFiles[id] { args += ["--cookies", c] }
        } else {
            if let r = item.referer { args += ["--referer", r] }
            if item.nameFixed { args += ["--name", item.name] }
            if item.skipExisting == true { args.append("--skip-existing") }
        }
        if !item.isConvert { args.append(item.url) }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let c = cookies[id] { env["DUALDL_COOKIE"] = c }
        p.environment = env
        p.qualityOfService = .utility      // lower CPU and disk priority than the apps you're using

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(id, d) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.runs[id]?.stderr.append(d) } }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            // Give the last stdout lines time to arrive first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self?.ended(id, code) }
            }
        }

        items[i].state = .running
        items[i].error = nil
        items[i].log = nil
        items[i].stage = item.isVideo ? "Reading the page…" : nil
        do {
            try p.run()
            runs[id] = Run(p)
        } catch {
            items[i].state = .failed
            items[i].error = "Engine start hoyni: \(error.localizedDescription)"
        }
    }

    private func consume(_ id: UUID, _ data: Data) {
        guard let run = runs[id] else { return }
        run.buffer.append(data)
        while let nl = run.buffer.firstIndex(of: 0x0A) {
            let line = Data(run.buffer[run.buffer.startIndex..<nl])
            run.buffer.removeSubrange(run.buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(id, obj)
            }
        }
    }

    private func handle(_ id: UUID, _ e: [String: Any]) {
        guard let i = index(id) else { return }
        func int(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }
        func ints(_ v: Any?) -> [String: Int64] {
            var out: [String: Int64] = [:]
            for (k, x) in v as? [String: Any] ?? [:] { out[k] = int(x) ?? 0 }
            return out
        }
        switch e["event"] as? String {
        case "lines":
            for l in e["lines"] as? [[String: Any]] ?? [] {
                if let f = l["iface"] as? String, let lab = l["label"] as? String { labels[f] = lab }
            }
        case "info":
            if let n = e["name"] as? String { items[i].name = n; items[i].nameFixed = !items[i].isVideo }
            items[i].path = e["path"] as? String
            items[i].size = int(e["size"])
            items[i].done = int(e["resumed"]) ?? 0
            if items[i].isVideo {
                if let t = e["thumbnail"] as? String, !t.isEmpty { items[i].thumbnail = t }
                if let q = e["quality"] as? String, !q.isEmpty { items[i].badge = q }
                if let w = e["work"] as? String { items[i].work = w }
                items[i].stage = nil
            }
            save()
        case "stage":
            items[i].stage = e["message"] as? String
        case "work":
            items[i].work = e["path"] as? String
            save()
        case "progress":
            items[i].done = int(e["done"]) ?? items[i].done
            if let s = int(e["size"]) { items[i].size = s }
            items[i].speeds = ints(e["speeds"]).mapValues(Double.init)
            let r = ints(e["received"])
            if !r.isEmpty { items[i].received = r }
            let down = e["down"] as? [String] ?? []
            if down != items[i].down { items[i].down = down }
        case "done" where items[i].isConvert:
            finishConvert(id, e)
        case "done":
            items[i].state = .completed
            items[i].path = e["path"] as? String ?? items[i].path
            items[i].elapsed = (e["elapsed"] as? NSNumber)?.doubleValue
            if let s = int(e["size"]) { items[i].size = s; items[i].done = s }
            let r = ints(e["received"])
            if !r.isEmpty { items[i].received = r }
            items[i].speeds = [:]
            items[i].down = []
            items[i].stage = nil
            items[i].finished = Date()
            items[i].retries = 0
            items[i].retryAt = nil
            if e["skipped"] as? Bool == true { items[i].log = "Already downloaded" }
            cookies[id] = nil
            removeCookieFile(id)
            notifyDone(items[i])
            if autoUnzip, !items[i].isVideo, Self.isZip(items[i].name) { unzip(id) }
            save()
        case "error":
            items[i].state = .failed
            items[i].error = e["message"] as? String
            items[i].speeds = [:]
            items[i].down = []
            items[i].stage = nil
            // Worth another go (expired link, Drive limiting, a line down): schedule it. Progress since
            // the last failure starts the count again, so a long download can keep going for hours.
            if e["retry"] as? Bool == true {
                if items[i].done > items[i].retryBase + (16 << 20) { items[i].retries = 0 }
                items[i].retryBase = items[i].done
                if items[i].retries < retryDelays.count {
                    items[i].retryAt = Date().addingTimeInterval(retryDelays[items[i].retries])
                    items[i].retries += 1
                }
            }
            save()
        case "paused":
            if items[i].state == .running { items[i].state = .paused }
            items[i].speeds = [:]
            items[i].down = []
        case "log":
            items[i].log = e["message"] as? String
        default:
            break
        }
    }

    private func ended(_ id: UUID, _ code: Int32) {
        guard let run = runs.removeValue(forKey: id) else { return }
        if let paths = run.cleanup {
            removeAll(paths)
        } else if let i = index(id), items[i].state == .running {
            if run.userStopped {
                items[i].state = .paused
            } else {
                items[i].state = .failed
                let tail = String(data: run.stderr, encoding: .utf8)?
                    .split(separator: "\n").last.map(String.init)
                items[i].error = tail ?? "Engine bondho hoye geche (code \(code))"
            }
            items[i].speeds = [:]
            items[i].down = []
            items[i].stage = nil
        }
        save()
        pump()
    }

    // MARK: - Actions

    func pause(_ id: UUID) {
        if let r = runs[id] {
            r.userStopped = true
            r.process.terminate()
        }
        if let i = index(id), items[i].state == .queued || items[i].state == .running {
            items[i].state = .paused
            items[i].speeds = [:]
        }
        save()
        updateBadge()
    }

    func resume(_ id: UUID, automatic: Bool = false) {
        guard let i = index(id), items[i].state == .paused || items[i].state == .failed else { return }
        // A note row (folder that couldn't be read) is retried by reading the folder again
        if items[i].kind == nil, isDriveFolderURL(items[i].url) {
            let url = items[i].url
            items.remove(at: i)
            save()
            listFolder(PendingAdd(url: url))
            return
        }
        items[i].state = .queued
        items[i].error = nil
        if !automatic { items[i].retryAt = nil; items[i].retries = 0 }
        save()
        pump()
    }

    func pauseAll() { for item in items where item.state == .running || item.state == .queued { pause(item.id) } }
    func resumeAll() {
        for item in items.reversed() where item.state == .paused || item.state == .failed { resume(item.id) }
    }

    /// The single toolbar button: pause everything if anything is active, otherwise resume.
    func toggleAll() { canPauseAll ? pauseAll() : resumeAll() }

    /// Restarts running downloads so a changed setting (speed limit) applies; progress is kept.
    func restartRunning() {
        for item in items where item.state == .running {
            pause(item.id)
            resume(item.id)
        }
    }

    /// Stops an unfinished download and deletes its partial file.
    func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        var leftovers = item.path.map { [$0 + ".dualdl-part", $0 + ".dualdl.json"] } ?? []
        if let w = item.work { leftovers.append(w) }
        if let r = runs[id], r.process.isRunning {
            r.cleanup = leftovers
            r.process.terminate()
        } else {
            removeAll(leftovers)
        }
        stopUnzip(id)
        items.removeAll { $0.id == id }
        cookies[id] = nil
        removeCookieFile(id)
        save()
        updateBadge()
    }

    /// Takes a finished download off the list; the file stays.
    func remove(_ id: UUID) {
        stopUnzip(id)
        items.removeAll { $0.id == id }
        save()
    }

    func clearCompleted() {
        let busy = ["queued", "running"]
        items.removeAll { $0.state == .completed && !busy.contains($0.unzip?.state ?? "") }
        save()
    }

    func trash(_ id: UUID) {
        if let p = items.first(where: { $0.id == id })?.path { Self.moveToTrash(p) }
        remove(id)
    }

    /// The Mac's Trash (recoverable). Under tests ($DUALDL_HOME) a "Trash" folder in there
    /// instead, so test files never land in the real Trash.
    static func moveToTrash(_ path: String, done: ((Error?) -> Void)? = nil) {
        if let h = ProcessInfo.processInfo.environment["DUALDL_HOME"] {
            let dir = URL(fileURLWithPath: h).appendingPathComponent("Trash")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(atPath: path, toPath: dir.appendingPathComponent(
                    UUID().uuidString + "-" + (path as NSString).lastPathComponent).path)
                done?(nil)
            } catch { done?(error) }
            return
        }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in done?(error) }
    }

    func reveal(_ id: UUID) {
        guard let p = items.first(where: { $0.id == id })?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    func open(_ id: UUID) {
        guard let p = items.first(where: { $0.id == id })?.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    func copyLink(_ id: UUID) {
        guard let u = items.first(where: { $0.id == id })?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u, forType: .string)
    }

    /// Only DualDL's own leftovers: partial files and video.py's hidden temp folder.
    private func removeAll(_ paths: [String]) {
        for p in paths where p.hasSuffix(".dualdl-part") || p.hasSuffix(".dualdl.json")
            || (p as NSString).lastPathComponent.hasPrefix(".dualdl-") {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    private func writeCookieFile(_ id: UUID, _ txt: String) {
        try? FileManager.default.createDirectory(at: cookieDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = cookieDir.appendingPathComponent(id.uuidString + ".txt")
        FileManager.default.createFile(atPath: file.path, contents: Data(txt.utf8),
                                       attributes: [.posixPermissions: 0o600])
        cookieFiles[id] = file.path
    }

    /// The Chrome login, while "Use my Chrome login for video sites" is on.
    var loginCookies: String? {
        guard defaults.bool(forKey: "useChromeCookies") else {
            chromeLogin = nil
            return nil
        }
        return chromeLogin
    }

    /// A private copy of the Chrome login for one yt-dlp run (yt-dlp rewrites the file it's given).
    func tempLoginFile() -> String? {
        guard let txt = loginCookies else { return nil }
        try? FileManager.default.createDirectory(at: cookieDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = cookieDir.appendingPathComponent("preview-\(UUID().uuidString).txt").path
        FileManager.default.createFile(atPath: file, contents: Data(txt.utf8), attributes: [.posixPermissions: 0o600])
        return file
    }

    private func removeCookieFile(_ id: UUID) {
        if let f = cookieFiles.removeValue(forKey: id) { try? FileManager.default.removeItem(atPath: f) }
    }

    // MARK: - Convert for Mac & Premiere

    static let videoExtensions = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "3gp", "ts"]

    static func isVideoFile(_ path: String) -> Bool {
        videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Queues a local video to be made QuickTime/Premiere-ready (VP9/AV1 → H.264/HEVC).
    func convert(path: String) {
        guard FileManager.default.fileExists(atPath: path), Self.isVideoFile(path),
              !items.contains(where: { $0.isConvert && $0.url == path && ($0.state == .queued || $0.state == .running) })
        else { return }
        var item = DownloadItem(url: path, name: (path as NSString).lastPathComponent)
        item.kind = "convert"
        item.folder = (path as NSString).deletingLastPathComponent
        item.badge = "Mac"
        items.insert(item, at: 0)
        save()
        pump()
    }

    func pickAndConvert() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.movie]
        p.prompt = "Convert"
        p.message = "Choose videos to make playable in QuickTime and Premiere (the originals go to the Trash)"
        NSApp.activate(ignoringOtherApps: true)
        p.begin { [weak self] resp in
            MainActor.assumeIsolated {
                guard resp == .OK else { return }
                for u in p.urls { self?.convert(path: u.path) }
            }
        }
    }

    /// The engine checked the new file; the original goes to the Trash (so it can be
    /// recovered) and the new one takes its place. If the Trash refuses, both are kept.
    private func finishConvert(_ id: UUID, _ e: [String: Any]) {
        guard let i = index(id) else { return }
        let original = e["original"] as? String ?? items[i].url
        func complete(_ path: String, note: String?) {
            guard let j = index(id) else { return }
            items[j].state = .completed
            items[j].path = path
            items[j].name = (path as NSString).lastPathComponent
            items[j].size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            items[j].done = items[j].size ?? 0
            items[j].stage = nil
            items[j].log = note
            items[j].finished = Date()
            items[j].work = nil
            notifyDone(items[j])
            save()
        }
        if e["already"] as? Bool == true {
            complete(original, note: "Already plays in QuickTime and Premiere")
            return
        }
        guard let tmp = e["path"] as? String, let target = e["target"] as? String else { return }
        items[i].stage = "Finishing…"
        Self.moveToTrash(original) { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var dest = target
                    if error != nil || FileManager.default.fileExists(atPath: target) {
                        let base = (target as NSString).deletingPathExtension
                        dest = base + " (Mac).mp4"
                        var n = 2
                        while FileManager.default.fileExists(atPath: dest) { dest = base + " (Mac \(n)).mp4"; n += 1 }
                    }
                    do {
                        try FileManager.default.moveItem(atPath: tmp, toPath: dest)
                        complete(dest, note: error == nil ? "Original moved to the Trash" : "Original kept")
                    } catch {
                        if let j = self.index(id) {
                            self.items[j].state = .failed
                            self.items[j].error = "Couldn't save the converted file: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    // MARK: - Unzip

    static func isZip(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".zip")
            || name.range(of: #"\.zip\.\d{3}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Queues a finished zip for unzip.py. One at a time: it's disk-heavy.
    func unzip(_ id: UUID) {
        guard let i = index(id), items[i].state == .completed, items[i].path != nil, Self.isZip(items[i].name),
              !unzipQueue.contains(id), unzipRun?.id != id else { return }
        items[i].unzip = UnzipInfo(state: "queued")
        unzipQueue.append(id)
        save()
        pumpUnzip()
    }

    func revealUnzipped(_ id: UUID) {
        guard let m = items.first(where: { $0.id == id })?.unzip?.main else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m)])
    }

    private func pumpUnzip() {
        guard unzipRun == nil, !unzipQueue.isEmpty else { return }
        let id = unzipQueue.removeFirst()
        guard let i = index(id), let path = items[i].path, FileManager.default.fileExists(atPath: path) else {
            if let i = index(id) { items[i].unzip = UnzipInfo(state: "failed", message: "The zip file isn't there any more") }
            pumpUnzip()
            return
        }
        items[i].unzip?.state = "running"
        if let p = Engine.run("unzip", [path], onEvent: { [weak self] e in self?.unzipEvent(id, e) },
                              onExit: { [weak self] code, tail in self?.unzipEnded(id, code, tail) }) {
            unzipRun = (id, p)
        }
        updateActivity()
    }

    private func unzipEvent(_ id: UUID, _ e: [String: Any]) {
        guard let i = index(id) else { return }
        let n = { (k: String) in (e[k] as? NSNumber)?.int64Value ?? 0 }
        switch e["event"] as? String {
        case "info":
            items[i].unzip?.main = e["main"] as? String
            items[i].unzip?.size = n("size")
        case "progress":
            items[i].unzip?.done = n("done")
            items[i].unzip?.size = n("size")
        case "done":
            items[i].unzip = UnzipInfo(state: "done", done: n("size"), size: n("size"), main: e["main"] as? String)
            finishSplitSiblings(of: i)
            if trashZips, let p = items[i].path {
                Self.moveToTrash(p)
                items[i].unzip?.message = "Zip moved to Trash"
            }
        case "waiting":
            items[i].unzip = UnzipInfo(state: "waiting", message: "Waiting for the other pieces")
        case "error":
            items[i].unzip = UnzipInfo(state: "failed", message: e["message"] as? String)
        default:
            break
        }
    }

    /// A split archive extracts when its last piece lands; the earlier pieces were "waiting".
    private func finishSplitSiblings(of i: Int) {
        guard let path = items[i].path,
              let r = path.range(of: #"\.zip\.\d{3}$"#, options: [.regularExpression, .caseInsensitive]) else { return }
        let base = String(path[..<r.lowerBound])
        for j in items.indices where j != i && items[j].unzip?.state == "waiting"
            && (items[j].path ?? "").hasPrefix(base + ".zip.") {
            items[j].unzip = items[i].unzip
        }
    }

    private func unzipEnded(_ id: UUID, _ code: Int32, _ tail: String) {
        unzipRun = nil
        if let i = index(id), items[i].unzip?.state == "running" {
            items[i].unzip = UnzipInfo(state: "failed", message: tail.isEmpty ? "Unzip stopped" : tail)
        }
        save()
        updateActivity()
        pumpUnzip()
    }

    private func stopUnzip(_ id: UUID) {
        unzipQueue.removeAll { $0 == id }
        if unzipRun?.id == id { unzipRun?.process.terminate() }
    }

    // MARK: - Chrome extension

    func startServer() {
        let s = LinkServer { [weak self] req in
            var video: VideoRequest?
            if req.kind == "video" {
                video = VideoRequest(mode: req.mode ?? "video", quality: req.quality ?? "best",
                                     audio: req.audio ?? "mp3", cookiesTxt: req.cookiesTxt, title: req.title)
            }
            return self?.add(url: req.url, cookie: req.cookie, referer: req.referer, filename: req.filename,
                             video: video) ?? false
        }
        s.onState = { [weak self] up in self?.serverRunning = up }
        s.onContact = { [weak self] in self?.lastExtensionContact = Date() }
        s.wantCookies = { UserDefaults.standard.bool(forKey: "useChromeCookies") }
        s.hasCookies = { [weak self] in self?.loginCookies != nil }
        s.onTurbo = { [weak self] on in
            TurboManager.shared.setEnabled(on, lines: self?.lines.filter(\.usable).map(\.iface) ?? [])
        }
        s.onCookies = { [weak self] txt in
            self?.chromeLogin = txt
            self?.chromeLoginAt = Date()
        }
        s.start()
        server = s
    }

    var extensionFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DualDL Chrome Extension")
    }

    /// Copies the bundled extension to ~/Documents (fresh copy, so updates land) and shows it.
    func revealExtension() {
        if let src = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) {
            try? FileManager.default.removeItem(at: extensionFolder)
            try? FileManager.default.copyItem(at: src, to: extensionFolder)
        }
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
    }

    func openChromeExtensions() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? p.run()
    }

    // MARK: - Network lines

    private func scheduleLineCheck() {
        recheck?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkLines() } }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)   // let the network settle
    }

    /// Asks each line for its public IP and ISP (through that line only), so we know
    /// whether Ethernet and Wi-Fi really are two different internet connections.
    func checkLines() {
        guard !checkingLines else { return }
        checkingLines = true
        let path = enginePath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [path, "--check-lines"]
            p.qualityOfService = .utility
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            var found: [NetLine]?
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                found = try? JSONDecoder().decode([NetLine].self, from: data)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkingLines = false
                    guard let found else { return }
                    if self.lines != found { self.lines = found }
                    for l in found { self.labels[l.iface] = l.label }
                    self.linesChecked = Date()
                    TurboManager.shared.update(lines: found.filter(\.usable).map(\.iface))
                }
            }
        }
    }

    // MARK: - Persistence and system

    private func load() {
        guard let d = try? Data(contentsOf: storeURL), !d.isEmpty else { return }
        let read = (try? JSONDecoder().decode([LossyItem].self, from: d)) ?? []
        var list = read.compactMap(\.item)
        let total = (try? JSONSerialization.jsonObject(with: d) as? [Any])?.count
        if total != list.count {
            // Something didn't read: keep the original file before the list is ever saved again.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? d.write(to: storeURL.deletingLastPathComponent().appendingPathComponent("downloads.unreadable-\(stamp).json"))
        }
        for i in list.indices where list[i].state == .running { list[i].state = .paused }
        for i in list.indices where list[i].unzip?.state == "running" { list[i].unzip?.state = "queued" }
        items = list
    }

    func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: storeURL, options: .atomic) }
    }

    /// Called on quit: every engine saves its progress so the download can resume later.
    func shutdown() {
        for r in runs.values {
            r.userStopped = true
            r.process.terminate()
        }
        unzipRun?.process.terminate()       // finished files are kept; it carries on next launch
        TurboManager.shared.stop()           // Chrome falls back to browsing directly
        for i in items.indices where items[i].unzip?.state == "running" { items[i].unzip?.state = "queued" }
        let deadline = Date().addingTimeInterval(3)
        while runs.values.contains(where: { $0.process.isRunning }) && Date() < deadline {
            usleep(50_000)
        }
        for i in items.indices where items[i].state == .running { items[i].state = .paused }
        save()
    }

    private func updateBadge() {
        let n = activeCount
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func notifyDone(_ item: DownloadItem) {
        updateBadge()
        guard notify else { return }
        let c = UNMutableNotificationContent()
        c.title = "Download complete"
        c.body = item.name
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: item.id.uuidString, content: c, trigger: nil))
    }
}
