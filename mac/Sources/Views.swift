import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The SDK also declares a `State` macro whose plugin ships only with Xcode;
/// naming the property wrapper through an alias lets the Command Line Tools build this.
typealias ViewState = SwiftUI.State

// MARK: - Formatting

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .binary
    f.allowsNonnumericFormatting = false     // "0 KB", not "Zero KB"
    return f
}()

func fmtBytes(_ b: Int64) -> String { byteFormatter.string(fromByteCount: b) }
func fmtSpeed(_ s: Double) -> String { s < 1024 ? "0 KB/s" : fmtBytes(Int64(s)) + "/s" }

func fmtTime(_ t: Double) -> String {
    let s = Int(t.rounded())
    if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
    if s >= 60 { return "\(s / 60)m \(s % 60)s" }
    return "\(s)s"
}

func lineColor(_ label: String) -> Color {
    label.contains("Ethernet") ? .blue : label.contains("WiFi") ? .teal : .orange
}

func lineSymbol(_ label: String) -> String {
    label.contains("Ethernet") ? "cable.connector.horizontal" : label.contains("WiFi") ? "wifi" : "network"
}

private let appIcon = NSApplication.shared.applicationIconImage ?? NSImage()

enum Filter: String, CaseIterable, Identifiable {
    case all = "All", active = "Active", done = "Completed"
    var id: String { rawValue }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var m: DownloadManager
    @ObservedObject private var wifi = WiFiNames.shared
    @ObservedObject private var tools = ToolsManager.shared
    @ObservedObject private var turbo = TurboManager.shared
    @AppStorage("turbo") private var turboOn = false
    @StateObject private var previewer = VideoPreviewer()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("watchClipboard") private var watchClipboard = true
    @AppStorage("videoMode") private var videoMode = "video"
    @AppStorage("videoQuality") private var videoQuality = "best"
    @AppStorage("audioFormat") private var audioFormat = "mp3"
    @AppStorage("useChromeCookies") private var useChromeLogin = false
    @ViewState private var forceVideo = false
    @ViewState private var link = ""
    @ViewState private var filter: Filter = .all
    @ViewState private var shake = false
    @ViewState private var dropping = false
    @ViewState private var lastClipboard = ""
    @FocusState private var focused: Bool

    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// One link that is a video page (or the film button is on): show the video options.
    private var videoActive: Bool {
        !trimmedLink.isEmpty && !trimmedLink.contains(where: \.isWhitespace) && (forceVideo || isVideoURL(trimmedLink))
    }

    private var shown: [DownloadItem] {
        switch filter {
        case .all: return m.items
        case .active: return m.items.filter { $0.state != .completed }
        case .done: return m.items.filter { $0.state == .completed }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if shown.isEmpty {
                EmptyStateView(filter: filter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { item in
                            DownloadRow(item: item, labels: m.labels, order: m.lines.map(\.iface))
                                .equatable()
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: m.items.map(\.id))
        .toolbar { toolbar }
        .onDrop(of: [.url, .plainText], isTargeted: $dropping, perform: drop)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkClipboard()
        }
        .onChange(of: m.pendingLink) { _, new in
            if let new {
                link = new
                m.pendingLink = nil
                focused = true
            }
        }
        .onAppear {
            checkClipboard()
            m.openMainWindow = { [openWindow] in openWindow(id: "main") }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { m.toggleAll() } label: {
                Label(m.canPauseAll ? "Pause All" : "Resume All",
                      systemImage: m.canPauseAll ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!m.canPauseAll && !m.canResumeAll)
            .help(m.canPauseAll ? "Pause every download" : "Resume paused downloads")
            Button { m.clearCompleted() } label: { Label("Clear Completed", systemImage: "checkmark.circle") }
                .disabled(!m.items.contains { $0.state == .completed })
                .help("Remove finished downloads from the list (files stay)")
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("Settings")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DualDL")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Ethernet and Wi-Fi, downloading together")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(fmtSpeed(m.totalSpeed))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("combined speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("Paste a download link or Google Drive share link", text: $link)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit(submit)
                    if !link.isEmpty {
                        Button { link = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { forceVideo.toggle() } label: {
                        Image(systemName: videoActive ? "film.fill" : "film")
                            .foregroundStyle(videoActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .help(videoActive ? "Downloading as a video page (yt-dlp). Click to treat it as a plain file."
                                      : "Treat this link as a video page (YouTube and 1,000+ other sites)")
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                                  lineWidth: focused ? 2 : 1))
                .offset(x: shake ? -8 : 0)

                Button(action: paste) { Label("Paste", systemImage: "doc.on.clipboard") }
                    .controlSize(.large)
                Button(action: submit) {
                    Label(videoActive ? (videoMode == "audio" ? "Download Audio" : "Download Video") : "Download",
                          systemImage: "arrow.down")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(trimmedLink.isEmpty || (videoActive && !tools.ytdlp.installed))
            }

            if videoActive {
                VideoCard(state: previewer.state, mode: $videoMode, quality: $videoQuality, audio: $audioFormat,
                          tools: tools) {
                    useChromeLogin = true
                    if m.chromeLoginAt == nil { previewer.waitForLogin(trimmedLink) } else { previewer.clear(); refreshPreview() }
                }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Narrow window: drop the ISP/speed text first, then the status words; never wrap.
            ViewThatFits(in: .horizontal) {
                pillsRow(detail: true, compactBadges: false)
                pillsRow(detail: false, compactBadges: false)
                pillsRow(detail: false, compactBadges: true)
            }
        }
        .padding(20)
        .background(.bar)
        .animation(.easeOut(duration: 0.2), value: videoActive)
        .onChange(of: link) { refreshPreview() }
        .onChange(of: forceVideo) { refreshPreview() }
        .onChange(of: tools.ytdlp) { refreshPreview() }       // the tools check finishes after launch
        .onChange(of: turboOn) { turbo.update(lines: m.lines.filter(\.usable).map(\.iface)) }
        .onChange(of: m.chromeLoginAt) {                       // login arrived: retry a failed preview
            if case .failed = previewer.state { previewer.clear(); refreshPreview() }
        }
    }

    private func pillsRow(detail: Bool, compactBadges: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(m.lines) { line in
                LinePill(line: line, speed: m.speed(for: line.iface), ssid: wifi.names[line.iface],
                         sameAsLabel: line.sameAs.map { m.label($0) }, showDetail: detail)
            }
            HealthBadge(health: m.health, distinctISPs: m.distinctISPs, checking: m.checkingLines,
                        compact: compactBadges) { m.checkLines() }
            TurboChip(on: turboOn, running: turbo.running, rate: turbo.totalRate, chrome: turbo.chromeApplied,
                      blocked: turbo.chromeBlocked, compact: compactBadges) { turboOn.toggle() }
            Spacer(minLength: 8)
            ExtensionPill(running: m.serverRunning, lastContact: m.lastExtensionContact, compact: compactBadges)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func refreshPreview() {
        if trimmedLink.isEmpty { forceVideo = false }
        if videoActive, tools.ytdlp.installed {
            previewer.load(trimmedLink, lines: m.lines.filter(\.usable).map(\.iface))
        } else {
            previewer.clear()
        }
    }

    private func submit() {
        var added = false
        if videoActive {
            var preview: VideoPreview?
            if case .ready(let u, let p) = previewer.state, u == trimmedLink { preview = p }
            added = m.add(url: trimmedLink, video: VideoRequest(mode: videoMode, quality: videoQuality,
                                                                 audio: audioFormat, title: preview?.title,
                                                                 thumbnail: preview?.thumbnail))
        } else {
            let parts = link.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for p in parts where m.add(url: p) { added = true }
        }
        if added {
            link = ""
            forceVideo = false
        } else {
            withAnimation(.interpolatingSpring(stiffness: 900, damping: 10)) { shake = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.interpolatingSpring(stiffness: 900, damping: 10)) { shake = false }
            }
        }
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) {
            link = s.trimmingCharacters(in: .whitespacesAndNewlines)
            focused = true
        }
    }

    /// Prefills the box with a freshly copied link; never starts it by itself.
    private func checkClipboard() {
        guard watchClipboard, link.isEmpty,
              let s = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("http"), !s.contains(" "), s != lastClipboard,
              !m.items.contains(where: { $0.url == s }) else { return }
        lastClipboard = s
        link = s
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.canLoadObject(ofClass: NSURL.self) {
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                    guard let url = obj as? NSURL else { return }
                    let local = url.isFileURL ? url.path : nil
                    let link = url.absoluteString
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let local { m.convert(path: local) } else if let link { _ = m.add(url: link) }
                        }
                    }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { _ = m.add(url: s) } }
                }
            }
        }
        return true
    }
}

// MARK: - Video options

/// Shown under the link box for video pages: what the video is, and how to save it.
struct VideoCard: View {
    let state: PreviewState
    @Binding var mode: String
    @Binding var quality: String
    @Binding var audio: String
    @ObservedObject var tools: ToolsManager
    var onUseLogin: () -> Void = {}

    private var preview: VideoPreview? {
        if case .ready(_, let p) = state { return p }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                if !tools.ytdlp.installed {
                    installPrompt
                } else {
                    info
                    HStack(spacing: 10) {
                        Picker("", selection: $mode) {
                            Label("Video", systemImage: "film").tag("video")
                            Label("Audio", systemImage: "music.note").tag("audio")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                        if mode == "video" { qualityMenu } else { audioMenu }
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 72)        // same height while loading and when ready: the list doesn't jump
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08))
            if let url = preview.flatMap({ URL(string: $0.thumbnail) }) {
                AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                    ProgressView().controlSize(.small)
                }
            } else if case .loading = state {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: mode == "audio" ? "music.note" : "play.rectangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            if let d = preview?.duration, d > 0 {
                Text(fmtDuration(d))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var info: some View {
        switch state {
        case .ready(_, let p):
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text([p.uploader, p.site].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        case .failed(_, let msg):
            HStack(alignment: .top, spacing: 10) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .help(msg)
                if msg.contains("not a bot") && !UserDefaults.standard.bool(forKey: "useChromeCookies") {
                    Button("Use My Chrome Login") { onUseLogin() }
                        .controlSize(.small)
                        .fixedSize()
                }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text("Reading video info…").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text("You can download right away; the best quality is picked for you.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var qualityMenu: some View {
        let qs = preview?.qualities.filter { $0.height >= 360 } ?? []
        let maxH = qs.first?.height
        return Picker("Quality", selection: $quality) {
            Text(verbatim: maxH.map { "Best (\(String($0))p)" } ?? "Best quality").tag("best")
            if qs.isEmpty {
                ForEach([2160, 1440, 1080, 720, 480], id: \.self) { Text(verbatim: "Up to \(String($0))p").tag(String($0)) }
            } else {
                ForEach(qs, id: \.height) { q in
                    Text(verbatim: String(q.height) + "p" + ((q.fps ?? 0) > 30 ? String(Int(q.fps!)) : "")
                         + (q.size > 0 ? "  ·  ~\(fmtBytes(q.size))" : "")).tag(String(q.height))
                }
            }
            Divider()
            Text("Plays everywhere (H.264)").tag("compatible")
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        .help("Best picks the highest resolution; at the same resolution it prefers H.264, which plays "
              + "in every app and needs the least CPU.")
    }

    private var audioMenu: some View {
        Picker("Format", selection: $audio) {
            Text("MP3" + ((preview?.mp3Size ?? 0) > 0 ? "  ·  ~\(fmtBytes(preview!.mp3Size))" : "")).tag("mp3")
            Text("Original (M4A, no re-encode)").tag("original")
        }
        .labelsHidden()
        .frame(maxWidth: 240)
        .help("MP3 is highest-quality VBR with the cover picture; Original keeps the site's audio as is.")
    }

    private var installPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Video downloads need yt-dlp").font(.system(size: 13, weight: .semibold))
            if tools.busy {
                HStack(spacing: 8) {
                    if let p = tools.progress { ProgressView(value: p).frame(width: 140) } else { ProgressView().controlSize(.small) }
                    Text(tools.message ?? "Installing…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Button("Install Video Tools") { tools.install() }
                    if let msg = tools.message {
                        Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Text("Downloads yt-dlp and Deno from their official GitHub releases (about 90 MB) and checks their checksums.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

func fmtDuration(_ d: Double) -> String {
    let s = Int(d.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Header pills

struct LinePill: View {
    let line: NetLine
    let speed: Double
    let ssid: String?              // Wi-Fi network name, when macOS shares it
    let sameAsLabel: String?
    var showDetail = true

    private var detail: String {
        if speed > 0 { return fmtSpeed(speed) }
        if line.ok == false { return "No internet" }
        if let other = sameAsLabel, !(line.sameAs ?? "").isEmpty { return "Same as \(other) · not used" }
        if let isp = line.isp, !isp.isEmpty { return isp }
        return line.publicIP ?? line.ip
    }

    private var tooltip: String {
        var t = "\(line.label) (\(line.iface))"
        if let ssid { t += "\nNetwork: \(ssid)" }
        t += "\nLocal IP: \(line.ip)"
        if let ip = line.publicIP, !ip.isEmpty { t += "\nPublic IP: \(ip)" }
        if let isp = line.isp, !isp.isEmpty { t += "\nISP: \(isp)" }
        if let ms = line.ms, line.ok == true { t += "\nResponse: \(ms) ms" }
        return t
    }

    var body: some View {
        let c = line.usable || line.ok == nil ? lineColor(line.label) : Color.gray
        HStack(spacing: 6) {
            Image(systemName: lineSymbol(line.label))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(c)
            Text(ssid ?? line.label)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
            if showDetail || line.ok == false {
                Text(detail.count > 24 ? detail.prefix(22).trimmingCharacters(in: .whitespaces) + "…" : detail)
                    .font(.system(size: 11))
                    .foregroundStyle(line.ok == false ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(c.opacity(0.12)))
        .overlay(Capsule().strokeBorder(c.opacity(0.28)))
        .opacity(line.ok == false || !(line.sameAs ?? "").isEmpty ? 0.7 : 1)
        .help(tooltip)
    }
}

/// Tells at a glance whether the lines really are separate internet connections.
struct HealthBadge: View {
    let health: LineHealth
    let distinctISPs: Bool
    let checking: Bool
    var compact = false
    let recheck: () -> Void

    var body: some View {
        let (text, symbol, color, help): (String, String, Color, String) = {
            switch health {
            case .checking:
                return ("Checking lines…", "antenna.radiowaves.left.and.right", .secondary,
                        "Finding out which ISP each line uses")
            case .separate(let n):
                return (distinctISPs ? "\(n) different ISPs" : "\(n) separate connections",
                        "checkmark.seal.fill", .green,
                        "Every line has its own public IP, so their speeds add up")
            case .sameConnection:
                return ("Same connection", "exclamationmark.triangle.fill", .orange,
                        "Two lines share one public IP (one ISP connection), so only one of them is used. "
                        + "Connect Wi-Fi to a different provider to get the speed boost.")
            case .single:
                return ("Only one line online", "exclamationmark.triangle.fill", .orange,
                        "Downloads use the one working line until the other comes back")
            case .offline:
                return ("No internet", "wifi.exclamationmark", .red, "None of the lines can reach the internet")
            }
        }()
        Button(action: recheck) {
            HStack(spacing: 5) {
                if checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).foregroundStyle(color)
                }
                if !compact { Text(text).fixedSize() }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help + "\nClick to check again.")
        .disabled(checking)
    }
}

/// Turbo browsing on/off, with the browsing speed while it's on.
struct TurboChip: View {
    let on: Bool
    let running: Bool
    let rate: Double
    let chrome: Bool
    let blocked: Bool
    var compact = false
    let toggle: () -> Void

    private var text: String {
        if !on { return "Turbo off" }
        if !running { return "Turbo starting…" }
        return rate > 1024 ? "Turbo \(fmtSpeed(rate))" : "Turbo on"
    }

    private var help: String {
        var t = on ? "Turbo browsing is on: Chrome's sites use the fastest line, spill onto the other line "
                   + "when it's full, and switch lines if one stops working. Each site keeps one line, so "
                   + "logins stay put. Click to turn off."
                   : "Turbo browsing: let Chrome use both lines (needs the DualDL Chrome extension). Click to turn on."
        if on && blocked { t += "\nAnother Chrome extension (a VPN?) controls Chrome's proxy, so Turbo can't apply." }
        else if on && running && !chrome { t += "\nWaiting for Chrome to pick it up (up to a minute)." }
        return t
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: on ? "bolt.fill" : "bolt.slash")
                    .foregroundStyle(on ? (blocked ? Color.red : Color.orange) : Color.secondary)
                if !compact { Text(text).fixedSize().monospacedDigit() }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(on ? Color.orange.opacity(0.14) : Color.primary.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct ExtensionPill: View {
    let running: Bool
    let lastContact: Date?
    var compact = false

    var body: some View {
        let linked = lastContact != nil
        HStack(spacing: 6) {
            Circle()
                .fill(running ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(compact ? "Chrome" : !running ? "Chrome link off" : linked ? "Chrome linked" : "Waiting for Chrome")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .help(running ? "Listening on 127.0.0.1:\(LinkServer.port) for the DualDL Chrome extension"
                      : "Port \(LinkServer.port) is busy, the Chrome extension can't reach the app")
    }
}

// MARK: - Rows

/// Equatable so SwiftUI only redraws the rows whose download actually changed;
/// finished rows stay untouched while another download updates twice a second.
struct DownloadRow: View, Equatable {
    let item: DownloadItem
    let labels: [String: String]
    let order: [String]
    @ViewState private var hover = false

    private var m: DownloadManager { .shared }

    static func == (a: DownloadRow, b: DownloadRow) -> Bool {
        a.item == b.item && a.labels == b.labels && a.order == b.order
    }

    private func label(_ iface: String) -> String { labels[iface] ?? iface }

    private func ordered(_ ifaces: [String]) -> [String] {
        ifaces.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
    }

    private var fraction: Double {
        guard let s = item.size, s > 0 else { return 0 }
        return min(1, Double(item.done) / Double(s))
    }

    private var speed: Double { item.speeds.values.reduce(0, +) }

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let b = item.badge {
                        Text(b)
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.6)))
                            .foregroundStyle(.secondary)
                    }
                    StateBadge(state: item.state, fraction: fraction, known: item.size != nil)
                    Spacer(minLength: 0)
                }
                if item.state != .completed {
                    SplitBar(fraction: fraction, segments: segments, dimmed: item.state != .running)
                        .frame(height: 6)
                }
                HStack(spacing: 10) {
                    Text(detail)
                        .foregroundStyle(item.state == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .lineLimit(item.state == .failed ? 2 : 1)
                        .truncationMode(.tail)
                        .help(item.state == .failed ? detail : "")
                    Spacer(minLength: 8)
                    lineShare
                }
                .font(.system(size: 11))
                .monospacedDigit()
                if let u = item.unzip {
                    UnzipLine(info: u, reveal: { m.revealUnzipped(item.id) }, retry: { m.unzip(item.id) },
                              open: { m.open(item.id) })
                }
            }
            actions
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hover ? 0.12 : 0.05), radius: hover ? 8 : 3, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .onTapGesture(count: 2) { if item.state == .completed { m.open(item.id) } }
        .contextMenu {
            if item.state == .completed {
                Button("Open") { m.open(item.id) }
                Button("Show in Finder") { m.reveal(item.id) }
                if let p = item.path, DownloadManager.isVideoFile(p) {
                    Button("Convert for Mac & Premiere") { m.convert(path: p) }
                }
                if DownloadManager.isZip(item.name) {
                    Button(item.unzip?.state == "done" ? "Unzip Again" : "Unzip") { m.unzip(item.id) }
                    if item.unzip?.main != nil { Button("Show Unzipped Folder") { m.revealUnzipped(item.id) } }
                }
                Divider()
            }
            Button("Copy Link") { m.copyLink(item.id) }
            Divider()
            if item.state == .completed {
                Button("Remove from List") { m.remove(item.id) }
                Button("Move File to Trash") { m.trash(item.id) }
            } else {
                Button("Cancel Download") { m.cancel(item.id) }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if item.isVideo {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08))
                if let t = item.thumbnail, let url = URL(string: t) {
                    AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                        Image(systemName: "film").foregroundStyle(.tertiary)
                    }
                } else {
                    Image(systemName: item.mode == "audio" ? "music.note" : "film").foregroundStyle(.tertiary)
                }
                if item.mode == "audio" {
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.65)))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(2)
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            FileIcon(name: item.name).frame(width: 40, height: 40)
        }
    }

    private var segments: [(Color, Double)] {
        let keys = ordered(Array(item.received.keys))
        let total = Double(item.received.values.reduce(0, +))
        guard total > 0 else { return [(Color.accentColor, 1)] }
        return keys.map { (lineColor(label($0)), Double(item.received[$0] ?? 0) / total) }
    }

    private var detail: String {
        let done = fmtBytes(item.done)
        let total = item.size.map(fmtBytes) ?? "?"
        switch item.state {
        case .queued:
            let base = item.done > 0 ? "Waiting · \(done) of \(total)" : "Waiting in queue…"
            return item.group.map { base + " · \($0)" } ?? base
        case .running:
            if let stage = item.stage { return stage }
            if item.size == nil && item.done == 0 { return item.log ?? "Connecting…" }
            var s = "\(done) of \(total) · \(fmtSpeed(speed))"
            if let size = item.size, speed > 0 { s += " · \(fmtTime(Double(size - item.done) / speed)) left" }
            return s
        case .paused:
            return item.done > 0 ? "Paused · \(done) of \(total)" : "Paused"
        case .failed:
            var s = item.error ?? "Failed"
            if let at = item.retryAt {
                s += " · retrying at " + at.formatted(date: .omitted, time: .shortened)
            }
            return s
        case .completed where item.isConvert:
            return [total, item.log].compactMap { $0 }.joined(separator: " · ")
        case .completed:
            var s = total
            if let note = item.log {
                s += " · " + note
            } else if let e = item.elapsed, e > 0, let size = item.size {
                s += " · \(fmtTime(e)) · avg \(fmtSpeed(Double(size) / e))"
            }
            return item.group.map { s + " · \($0)" } ?? s
        }
    }

    private var shareKeys: [String] {
        let keys = item.state == .running ? Array(item.speeds.keys) : Array(item.received.keys)
        return ordered(keys)
    }

    private func shareText(_ k: String) -> String {
        if item.state == .running && item.down.contains(k) { return "\(label(k)) reconnecting…" }
        if item.state == .running { return "\(label(k)) \(fmtSpeed(item.speeds[k] ?? 0))" }
        let total = Double(max(1, item.received.values.reduce(0, +)))
        let pct = Int((Double(item.received[k] ?? 0) / total * 100).rounded())
        return "\(label(k)) \(pct)%"
    }

    @ViewBuilder private var lineShare: some View {
        if item.state == .running || item.state == .completed {
            HStack(spacing: 10) {
                ForEach(shareKeys, id: \.self) { k in
                    HStack(spacing: 4) {
                        Circle().fill(lineColor(label(k))).frame(width: 6, height: 6)
                        Text(shareText(k))
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch item.state {
            case .running, .queued:
                IconButton("pause.fill", "Pause") { m.pause(item.id) }
            case .paused:
                IconButton("play.fill", "Resume") { m.resume(item.id) }
            case .failed:
                IconButton("arrow.clockwise", "Try again") { m.resume(item.id) }
            case .completed:
                IconButton("magnifyingglass", "Show in Finder") { m.reveal(item.id) }
                IconButton("arrow.up.forward.app", "Open") { m.open(item.id) }
            }
            if item.state == .completed {
                IconButton("xmark", "Remove from list (file stays)") { m.remove(item.id) }
            } else {
                IconButton("xmark", "Cancel and delete the partial file") { m.cancel(item.id) }
            }
        }
    }
}

/// The unzip status under a finished zip.
struct UnzipLine: View {
    let info: UnzipInfo
    let reveal: () -> Void
    let retry: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch info.state {
            case "queued":
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                Text("Waiting to unzip…").foregroundStyle(.secondary)
            case "running":
                Image(systemName: "archivebox").foregroundStyle(Color.accentColor)
                Text(info.size > 0 ? "Unzipping \(Int(Double(info.done) / Double(info.size) * 100))%" : "Unzipping…")
                    .foregroundStyle(.secondary)
                if info.size > 0 {
                    ProgressView(value: Double(info.done), total: Double(info.size)).frame(width: 90).controlSize(.mini)
                }
            case "done":
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button(action: reveal) {
                    Text("Unzipped to “\(((info.main ?? "") as NSString).lastPathComponent)”")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(info.main ?? "")
                if let m = info.message { Text("· \(m)").foregroundStyle(.tertiary) }
            case "waiting":
                Image(systemName: "hourglass").foregroundStyle(.orange)
                Text(info.message ?? "Waiting for the other pieces").foregroundStyle(.secondary)
            default:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(info.message ?? "Unzip failed").foregroundStyle(.red).lineLimit(1).help(info.message ?? "")
                if (info.message ?? "").contains("password") {
                    Button("Open", action: open).buttonStyle(.link)
                } else {
                    Button("Retry", action: retry).buttonStyle(.link)
                }
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
    }
}

struct SplitBar: View {
    let fraction: Double
    let segments: [(Color, Double)]
    let dimmed: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                        Rectangle()
                            .fill(s.0.gradient)
                            .frame(width: max(0, g.size.width * fraction * s.1))
                    }
                }
                .clipShape(Capsule())
                .opacity(dimmed ? 0.45 : 1)
            }
        }
    }
}

struct StateBadge: View {
    let state: DLState
    let fraction: Double
    let known: Bool

    var body: some View {
        let (text, color): (String, Color) = {
            switch state {
            case .queued: return ("Queued", .gray)
            case .running: return (known ? "\(Int(fraction * 100))%" : "Starting", .accentColor)
            case .paused: return ("Paused", .orange)
            case .failed: return ("Failed", .red)
            case .completed: return ("Done", .green)
            }
        }()
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @ViewState private var hover = false

    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.13 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct FileIcon: View {
    let name: String

    private static var cache: [String: NSImage] = [:]

    /// Asking Launch Services for an icon on every redraw is slow; one per file type is enough.
    static func cached(_ ext: String, _ type: UTType) -> NSImage {
        if let img = cache[ext] { return img }
        let img = NSWorkspace.shared.icon(for: type)
        cache[ext] = img
        return img
    }

    var body: some View {
        let ext = (name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : UTType(filenameExtension: ext) ?? .data
        Image(nsImage: FileIcon.cached(ext.lowercased(), type))
            .resizable()
            .interpolation(.high)
    }
}

struct EmptyStateView: View {
    let filter: Filter

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: filter == .done ? "checkmark.circle" : "arrow.down.circle.dotted")
                .font(.system(size: 54, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(filter == .done ? "No completed downloads" : "No downloads yet")
                .font(.title3.weight(.semibold))
            Text("Paste a link above, drop one onto this window,\nor click any download in Chrome.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}

struct ToolRow: View {
    let name: String
    let info: ToolInfo
    let purpose: String

    var body: some View {
        LabeledContent {
            if info.installed {
                Text(info.version ?? "installed").foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("Not installed").foregroundStyle(.orange)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var m: DownloadManager
    @AppStorage("folder") private var folder = NSHomeDirectory() + "/Downloads"
    @AppStorage("connections") private var connections = 4
    @AppStorage("maxConcurrent") private var maxConcurrent = 1
    @AppStorage("notify") private var notify = true
    @AppStorage("watchClipboard") private var watchClipboard = true
    @AppStorage("askLocation") private var askLocation = true
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("limitOn") private var limitOn = false
    @AppStorage("limitMB") private var limitMB = 5.0
    @AppStorage("autoUnzip") private var autoUnzip = true
    @AppStorage("trashZips") private var trashZips = false
    @AppStorage("autoUpdateTools") private var autoUpdateTools = true
    @AppStorage("useChromeCookies") private var useChromeCookies = false
    @AppStorage("turbo") private var turboOn = false
    @AppStorage("compatVideos") private var compatVideos = true
    @ObservedObject private var turbo = TurboManager.shared
    @ObservedObject private var tools = ToolsManager.shared
    @ObservedObject private var wifi = WiFiNames.shared

    var body: some View {
        TabView {
            Form {
            Section("Downloads") {
                Toggle("Ask where to save each download", isOn: $askLocation)
                LabeledContent(askLocation ? "Start the picker in" : "Save to") {
                    HStack {
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: choose)
                    }
                }
                Stepper(value: $connections, in: 1...8) {
                    LabeledContent("Connections per line", value: "\(connections)")
                }
                Picker("Downloads at the same time", selection: $maxConcurrent) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section {
                Toggle("Unzip .zip downloads automatically", isOn: $autoUnzip)
                Toggle("Move the zip to Trash after unzipping", isOn: $trashZips)
                    .disabled(!autoUnzip)
            } header: {
                Text("Zip files")
            } footer: {
                Text("Google Drive splits big folders into “…-001.zip”, “…-002.zip”: each piece is unzipped "
                     + "into the same main folder as it finishes. Split archives (.zip.001) unzip once every "
                     + "piece is there.")
                    .foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Notify when a download finishes", isOn: $notify)
                Toggle("Suggest links I copy", isOn: $watchClipboard)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            Form {
            if let link = wifi.link {
                Section {
                    LabeledContent("Network", value: link.ssid ?? "Wi-Fi")
                    LabeledContent("Band") {
                        Text("\(link.band) · channel \(link.channel) · \(link.width) MHz")
                            .foregroundStyle(link.band.hasPrefix("2") ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    }
                    LabeledContent("Signal") {
                        Text("\(link.rssi) dBm · \(WiFiNames.quality(link.rssi))")
                            .foregroundStyle(link.rssi < -70 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    }
                    LabeledContent("Link speed", value: "\(Int(link.rate)) Mbps")
                    HStack {
                        Button(wifi.scanning ? "Looking…" : "Look for a Faster Band") { wifi.findFasterBand() }
                            .disabled(wifi.scanning)
                        if wifi.scanning { ProgressView().controlSize(.small) }
                    }
                    if let r = wifi.scanResult {
                        Text(r).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Wi-Fi check")
                } footer: {
                    Text(link.band.hasPrefix("2")
                         ? "2.4 GHz is crowded and slow. A 5 GHz connection to the same router is usually 3–5× faster for browsing."
                         : "Looking for a faster band briefly pauses Wi-Fi for a second or two while it scans.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Turbo browsing in Chrome", isOn: $turboOn)
                if turboOn {
                    LabeledContent("Proxy") {
                        Text(turbo.running ? "Running · \(turbo.tunnels) connections" : (turbo.message ?? "Starting…"))
                            .foregroundStyle(turbo.running ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    }
                    LabeledContent("Chrome") {
                        Text(turbo.chromeBlocked ? "Another extension controls Chrome's proxy"
                             : turbo.chromeApplied ? "Using Turbo" : "Waiting for the extension (up to a minute)")
                            .foregroundStyle(turbo.chromeApplied ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    }
                    ForEach(m.lines.filter { turbo.capacities[$0.iface] != nil }) { line in
                        LabeledContent(line.label) {
                            Text("\(fmtSpeed(turbo.rates[line.iface] ?? 0)) now · up to \(fmtSpeed(turbo.capacities[line.iface] ?? 0))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Turbo browsing")
            } footer: {
                Text("Chrome's secure (https) sites go through DualDL: each site sticks to one line so logins "
                     + "stay put, the fastest line is used first and the other line takes new sites when it's "
                     + "full or the fast one stops working. One video or page doesn't get faster, but many "
                     + "tabs and downloads together do. With DualDL closed, Chrome browses directly as usual.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Limit download speed", isOn: $limitOn)
                if limitOn {
                    Picker("Maximum per download", selection: $limitMB) {
                        ForEach([1.0, 2, 3, 5, 8, 10, 15, 20], id: \.self) { Text("\(Int($0)) MB/s").tag($0) }
                    }
                }
                Toggle("Keep the Mac awake while downloading", isOn: $keepAwake)
            } header: {
                Text("Sharing the connection")
            } footer: {
                Text("A limit leaves bandwidth for calls, games and browsing. Downloads always run at low "
                     + "priority so the apps you're using stay smooth. The display can still sleep.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(m.lines) { line in
                    LabeledContent {
                        Text(lineSummary(line))
                            .foregroundStyle(line.usable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    } label: {
                        Label(line.label, systemImage: lineSymbol(line.label))
                    }
                }
                HStack {
                    Button(m.checkingLines ? "Checking…" : "Check Lines Now") { m.checkLines() }
                        .disabled(m.checkingLines)
                    if !wifi.authorized {
                        Button("Show Wi-Fi Name…") { wifi.requestAccess() }
                            .help("macOS only shares the Wi-Fi network name with apps that have Location access. "
                                  + "DualDL never reads your location.")
                    }
                }
            } header: {
                Text("Internet lines")
            } footer: {
                Text("DualDL asks ipinfo.io for each line's public IP and ISP when it starts, every five "
                     + "minutes and whenever the network changes. Lines that are offline, or that share "
                     + "one connection, are left out of downloads automatically.")
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Network", systemImage: "network") }
            Form {
            Section {
                ToolRow(name: "yt-dlp", info: tools.ytdlp, purpose: "reads video pages")
                ToolRow(name: "Deno", info: tools.deno, purpose: "unlocks YouTube's best formats")
                ToolRow(name: "ffmpeg", info: tools.ffmpeg, purpose: "joins video + audio, makes MP3")
                HStack {
                    Button(tools.ytdlp.installed ? "Update Now" : "Install") { tools.install() }
                        .disabled(tools.busy)
                    if tools.busy {
                        if let p = tools.progress { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                    }
                    if let msg = tools.message { Text(msg).foregroundStyle(.secondary).lineLimit(1) }
                }
                Toggle("Make videos open in QuickTime and Premiere", isOn: $compatVideos)
                    .help("Above 1080p YouTube only sends VP9/AV1, which QuickTime and Premiere can't open. "
                          + "DualDL converts those to H.264 (up to 1080p) or HEVC with the Mac's hardware "
                          + "encoder, so it's quick and barely uses the CPU. Files that are already H.264/HEVC "
                          + "are never re-encoded.")
                Toggle("Keep yt-dlp up to date (checks weekly)", isOn: $autoUpdateTools)
            } header: {
                Text("Video downloads")
            } footer: {
                Text("Installs come from the official GitHub releases and are checked against their published "
                     + "SHA-256. Sites change often, so an up-to-date yt-dlp avoids most errors. "
                     + (tools.ffmpeg.installed ? "" : "ffmpeg wasn't found: install it (e.g. from martin-riedl.de) "
                        + "to get the best quality and MP3."))
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Video", systemImage: "film") }
            Form {
            Section {
                Toggle("Use my Chrome login for video sites", isOn: $useChromeCookies)
                    .help("Fixes “confirm you're not a bot”, age and members-only errors for links pasted here. "
                          + "The DualDL Chrome extension hands the app your login for video sites; it stays "
                          + "in memory and is never written to disk except for the moment yt-dlp uses it.")
                if useChromeCookies {
                    HStack(spacing: 6) {
                        if let at = m.chromeLoginAt {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Login received from Chrome \(at.formatted(.relative(presentation: .named)))")
                        } else {
                            Image(systemName: "hourglass").foregroundStyle(.orange)
                            Text("Waiting for Chrome: keep Chrome open with the DualDL extension (up to a minute)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Video sites")
            } footer: {
                Text("macOS keeps other apps out of Chrome's cookies, so the extension hands DualDL your login "
                     + "for video sites while this is on. It fixes “confirm you're not a bot”, age and "
                     + "members-only errors for links you paste here.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(m.serverRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(m.serverRunning ? "Listening on 127.0.0.1:\(LinkServer.port)" : "Not running")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Show Extension Folder") { m.revealExtension() }
                    Button("Open Chrome Extensions") { m.openChromeExtensions() }
                }
            } header: {
                Text("Chrome extension")
            } footer: {
                Text("In Chrome, turn on Developer mode, click Load unpacked and choose the “DualDL Chrome Extension” folder.")
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Chrome", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 560, height: 540)
        .onChange(of: maxConcurrent) { m.pump() }
        .onChange(of: limitOn) { m.restartRunning() }
        .onChange(of: limitMB) { if limitOn { m.restartRunning() } }
        .onChange(of: turboOn) { turbo.update(lines: m.lines.filter(\.usable).map(\.iface)) }
        .onAppear { wifi.refresh() }
    }

    private func lineSummary(_ l: NetLine) -> String {
        if l.ok == nil { return "Not checked yet" }
        if l.ok == false { return "No internet" }
        if let other = l.sameAs, !other.isEmpty { return "Same connection as \(m.label(other)), not used" }
        let isp = (l.isp ?? "").isEmpty ? "Unknown ISP" : l.isp!
        return "\(isp) · \(l.publicIP ?? "")"
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: folder)
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }
}
