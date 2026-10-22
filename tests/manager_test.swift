// End-to-end tests of the app's DownloadManager against tests/range_server.py over
// loopback (no internet). Built by run.sh together with the app's sources.
//
//   DUALDL_HOME=<tmp> DUALDL_PORT=<port> manager_test <work dir> <server port>
//
// <work dir>/srv holds what the server serves and the expected results.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)        // keep results even if something crashes
let WORK = CommandLine.arguments[1]
let SRV = "http://127.0.0.1:\(CommandLine.arguments[2])"
let OUT = WORK + "/dl"
let API = "http://127.0.0.1:\(ProcessInfo.processInfo.environment["DUALDL_PORT"] ?? "")"
var failures = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : " — " + detail()))
    if !ok { failures += 1 }
}

/// Tests run on a background thread; the manager (and its local server) live on main.
func onMain<T>(_ f: @MainActor () -> T) -> T { DispatchQueue.main.sync { MainActor.assumeIsolated { f() } } }

func waitFor(_ secs: Double, _ cond: @MainActor () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end {
        if onMain(cond) { return true }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return false
}

func shell(_ c: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", c]
    let o = Pipe()
    p.standardOutput = o
    try! p.run()
    p.waitUntilExit()
    return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func item(_ url: String) -> DownloadItem? { onMain { DownloadManager.shared.items.first { $0.url == url } } }
func same(_ a: String, _ b: String) -> Bool { FileManager.default.contentsEqual(atPath: a, andPath: b) }
func leftovers() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: OUT))?.filter { $0.contains(".dualdl") } ?? []
}
func engines() -> Int { Int(shell("pgrep -f 'dualdl.py --json' | wc -l")) ?? -1 }

let ud = UserDefaults.standard
for (k, v) in ["notify": false, "askLocation": false, "autoUnzip": true, "trashZips": false,
               "autoUpdateTools": false, "useChromeCookies": false, "keepAwake": false] as [String: Any] {
    ud.set(v, forKey: k)
}
ud.set(1, forKey: "maxConcurrent")
ud.set(4, forKey: "connections")
ud.set(OUT, forKey: "folder")
try? FileManager.default.createDirectory(atPath: OUT, withIntermediateDirectories: true)
// A list saved by an older version (fields missing), one with an unknown state, and one broken
// entry: the first two must load, the broken one is skipped, and the original file is kept.
let home = ProcessInfo.processInfo.environment["DUALDL_HOME"]! + "/Support"
try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
try! #"[{"id":"7E2B3C4D-0000-4000-8000-000000000001","url":"https://example.invalid/old.zip","name":"old.zip","nameFixed":false,"done":5,"state":"completed","added":700000000,"received":{}},"#
    .appending(#"{"url":"https://example.invalid/new.bin","name":"new.bin","state":"someFutureState"},{"name":"no url"}]"#)
    .write(toFile: home + "/downloads.json", atomically: true, encoding: .utf8)
MainActor.assumeIsolated { DownloadManager.shared.startServer() }
let loaded = MainActor.assumeIsolated { DownloadManager.shared.items.map(\.name) }
check(loaded == ["old.zip", "new.bin"], "an older saved list loads (missing fields take defaults)", "\(loaded)")
check(((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).contains { $0.hasPrefix("downloads.unreadable-") },
      "the original list is kept when an entry can't be read")

Thread.detachNewThread {
    // Only the loopback line, so nothing here touches the internet; and no later line
    // re-check may replace it (a check "in progress" makes checkLines() a no-op).
    _ = waitFor(40) { DownloadManager.shared.linesChecked != nil }
    onMain {
        let m = DownloadManager.shared
        m.checkingLines = true
        m.lines = [NetLine(iface: "lo0", label: "Loopback", ip: "127.0.0.1", ok: true, publicIP: "127.0.0.1",
                           isp: "test", ms: 0, sameAs: "")]
        for i in m.items { m.remove(i.id) }
    }

    // 1. A plain download arrives intact
    let a = SRV + "/a.bin"
    onMain { _ = DownloadManager.shared.add(url: a) }
    check(waitFor(60) { DownloadManager.shared.items.first { $0.url == a }?.state == .completed }, "download completes")
    check(same(OUT + "/a.bin", WORK + "/srv/a.bin"), "downloaded file is byte-identical")

    // 2. Pause, then resume where it stopped
    let b = SRV + "/b.bin"
    onMain { _ = DownloadManager.shared.add(url: b) }
    check(waitFor(30) { (DownloadManager.shared.items.first { $0.url == b }?.done ?? 0) > 6 << 20 }, "second download starts")
    let bid = item(b)!.id                  // look it up first: item() itself hops to main
    onMain { DownloadManager.shared.pause(bid) }
    check(waitFor(5) { DownloadManager.shared.items.first { $0.url == b }?.state == .paused }, "pause takes effect")
    Thread.sleep(forTimeInterval: 1.5)
    check(engines() == 0, "paused download has no engine running", "\(engines()) running")
    check(FileManager.default.fileExists(atPath: OUT + "/b.bin.dualdl-part"), "partial file is kept while paused")
    let before = item(b)?.done ?? 0
    onMain { DownloadManager.shared.resume(bid) }
    check(waitFor(90) { DownloadManager.shared.items.first { $0.url == b }?.state == .completed }, "resumed download completes")
    check(same(OUT + "/b.bin", WORK + "/srv/b.bin"), "resumed file is byte-identical", "had \(before) bytes before resume")

    // 3. Cancel removes the item and every partial file
    let c = SRV + "/c.bin"
    onMain { _ = DownloadManager.shared.add(url: c) }
    check(waitFor(30) { (DownloadManager.shared.items.first { $0.url == c }?.done ?? 0) > 4 << 20 }, "third download starts")
    let cid = item(c)!.id
    onMain { DownloadManager.shared.cancel(cid) }
    check(item(c) == nil, "cancelled item leaves the list at once")
    Thread.sleep(forTimeInterval: 2)
    check(leftovers().isEmpty && !FileManager.default.fileExists(atPath: OUT + "/c.bin"),
          "cancel leaves no partial files", "\(leftovers())")

    // 4. Google Drive pieces download and unzip into one folder
    let parts = ["001", "002", "003"].map { SRV + "/Holiday%20Videos%20-20260101T120000Z-1-\($0).zip" }
    for p in parts { onMain { _ = DownloadManager.shared.add(url: p) } }
    check(waitFor(120) { parts.allSatisfy { p in DownloadManager.shared.items.first { $0.url == p }?.unzip?.state == "done" } },
          "every Drive piece downloads and unzips",
          "\(parts.map { p in item(p).map { "\($0.state.rawValue)/\($0.unzip?.state ?? "-")" } ?? "missing" })")
    check(shell("diff -r '\(WORK)/srv/expected/Holiday Videos' '\(OUT)/Holiday Videos' && echo same") == "same",
          "the pieces merge into one identical folder")

    // 5. Split archive: earlier pieces wait, the last one unzips the whole thing
    let split = ["001", "002", "003"].map { SRV + "/big.zip.\($0)" }
    onMain { _ = DownloadManager.shared.add(url: split[0]) }
    check(waitFor(60) { DownloadManager.shared.items.first { $0.url == split[0] }?.unzip?.state == "waiting" },
          "first split piece waits for the others")
    for p in split.dropFirst() { onMain { _ = DownloadManager.shared.add(url: p) } }
    check(waitFor(120) { split.allSatisfy { p in DownloadManager.shared.items.first { $0.url == p }?.unzip?.state == "done" } },
          "all split pieces end as unzipped")
    check(shell("diff -r '\(WORK)/srv/expected/Big' '\(OUT)/Big' && echo same") == "same", "split archive content is intact")

    // 6. A Google Drive folder link: every file, in the folder's own structure; re-adding skips them
    let folderURL = SRV + "/drive/folders/F1"
    let names = ["A clip.mov", "B clip.mov", "C clip.mov"]
    func folderItems() -> [DownloadItem] { onMain { DownloadManager.shared.items.filter { $0.group == "Test Folder" } } }
    onMain { _ = DownloadManager.shared.add(url: folderURL) }
    check(waitFor(120) { names.allSatisfy { n in DownloadManager.shared.items.first { $0.name == n && $0.group == "Test Folder" }?.state == .completed } },
          "every file of a Drive folder downloads", "\(folderItems().map { "\($0.name) \($0.state.rawValue) \($0.error ?? "")" })")
    check(same(OUT + "/Test Folder/A clip.mov", WORK + "/srv/fileA") && same(OUT + "/Test Folder/B clip.mov", WORK + "/srv/fileB")
          && same(OUT + "/Test Folder/Sub/C clip.mov", WORK + "/srv/fileC"), "folder files land in the folder's own structure, intact")
    let firstRound = folderItems().map(\.id)
    onMain { for id in firstRound { DownloadManager.shared.remove(id) } }
    onMain { _ = DownloadManager.shared.add(url: folderURL) }
    check(waitFor(60) { names.allSatisfy { n in DownloadManager.shared.items.first { $0.name == n && $0.group == "Test Folder" }?.log == "Already downloaded" } },
          "re-adding the folder skips files that are already here")
    check(!FileManager.default.fileExists(atPath: OUT + "/Test Folder/A clip (1).mov"), "…without duplicates")

    // 7. A temporary failure retries on its own: dead server → "retry later" → back → finishes
    FileManager.default.createFile(atPath: WORK + "/srv/.down", contents: nil)
    let r = SRV + "/page/retry.bin"
    onMain { _ = DownloadManager.shared.add(url: r) }
    check(waitFor(120) { DownloadManager.shared.items.first { $0.url == r }.map { $0.state == .failed && $0.retryAt != nil } ?? false },
          "a temporary failure schedules an automatic retry", "\(item(r).map { "\($0.state.rawValue) \($0.error ?? "")" } ?? "missing")")
    try? FileManager.default.removeItem(atPath: WORK + "/srv/.down")
    check(waitFor(120) { DownloadManager.shared.items.first { $0.url == r }?.state == .completed }, "it resumes by itself and finishes")
    check(same(OUT + "/retry.bin", WORK + "/srv/retry.bin"), "the retried file is byte-identical")

    // 8. The local link server only talks to the extension
    let hdr = "-H 'X-DualDL: 1' -H 'Origin: chrome-extension://test' --max-time 5"
    check(shell("curl -s \(hdr) \(API)/ping").contains("\"ok\":true"), "extension ping answered")
    check(shell("curl -s -o /dev/null -w '%{http_code}' --max-time 5 \(API)/ping") == "403", "request without the header refused")
    check(shell("curl -s -o /dev/null -w '%{http_code}' -H 'X-DualDL: 1' -H 'Origin: https://evil.example' --max-time 5 \(API)/ping") == "403",
          "web page origin refused")
    check(shell("curl -s -o /dev/null -w '%{http_code}' -X OPTIONS --max-time 5 \(API)/add") == "403", "CORS preflight refused")
    let body = WORK + "/login.json"
    try! ##"{"cookiesTxt":"# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tx\n"}"##
        .write(toFile: body, atomically: true, encoding: .utf8)
    let post = "curl -s -o /dev/null -w '%{http_code}' \(hdr) -H 'Content-Type: application/json' --data-binary @\(body) \(API)/cookies"
    check(shell(post) == "403", "login refused while the setting is off")
    ud.set(true, forKey: "useChromeCookies")
    check(shell(post) == "200" && onMain { DownloadManager.shared.loginCookies != nil }, "login accepted while on")
    if let f = onMain({ DownloadManager.shared.tempLoginFile() }) {
        let perms = (try! FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as! NSNumber).intValue
        check(perms == 0o600, "login file is private (0600)", String(perms, radix: 8))
        try? FileManager.default.removeItem(atPath: f)
    }
    ud.set(false, forKey: "useChromeCookies")
    check(onMain { DownloadManager.shared.loginCookies == nil }, "login forgotten when switched off")

    // 9. Convert for Mac & Premiere: the new file takes the old one's place, the original goes to the
    //    (test) Trash; a cancelled conversion leaves the original alone and no temp file behind
    let clip = WORK + "/srv/clip.webm", long = WORK + "/srv/long.webm"
    let probe = "PATH=$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin ffprobe -v error -show_entries stream=codec_name -of csv=p=0"
    if FileManager.default.fileExists(atPath: clip) {
        onMain { DownloadManager.shared.convert(path: clip) }
        check(waitFor(90) { DownloadManager.shared.items.first { $0.isConvert && $0.url == clip }?.state == .completed },
              "a VP9 video converts from the app")
        let out = onMain { DownloadManager.shared.items.first { $0.isConvert && $0.url == clip }?.path } ?? ""
        check(out == WORK + "/srv/clip.mp4" && shell("\(probe) '\(out)'").contains("h264"),
              "the converted .mp4 takes the original's place", out)
        let trash = (try? FileManager.default.contentsOfDirectory(atPath: WORK + "/home/Trash")) ?? []
        check(!FileManager.default.fileExists(atPath: clip) && trash.contains { $0.hasSuffix("clip.webm") },
              "the original went to the Trash (recoverable)", "\(trash)")

        onMain { DownloadManager.shared.convert(path: long) }
        check(waitFor(60) { (DownloadManager.shared.items.first { $0.isConvert && $0.url == long }?.stage ?? "")
                .contains("Converting") }, "a long conversion shows its progress")
        let lid = item(long)?.id ?? UUID()
        onMain { DownloadManager.shared.cancel(lid) }
        Thread.sleep(forTimeInterval: 2)
        let temps = ((try? FileManager.default.contentsOfDirectory(atPath: WORK + "/srv")) ?? []).filter { $0.hasPrefix(".dualdl-convert") }
        check(FileManager.default.fileExists(atPath: long) && temps.isEmpty,
              "a cancelled conversion keeps the original and leaves no temp file", "\(temps)")
    } else {
        print("SKIP convert tests (no VP9 encoder in this ffmpeg)")
    }

    // 10. Turbo browsing: the proxy follows the setting, from the app or the extension
    let turboPort = ProcessInfo.processInfo.environment["DUALDL_TURBO_PORT"] ?? "51978"
    func turboListening() -> Bool { !shell("lsof -nP -iTCP:\(turboPort) -sTCP:LISTEN 2>/dev/null | tail -n +2").isEmpty }
    ud.set(true, forKey: "turbo")
    onMain { TurboManager.shared.update(lines: ["lo0"]) }
    check(waitFor(10) { TurboManager.shared.running }, "Turbo proxy starts when switched on")
    check(turboListening(), "Turbo proxy listens on its port")
    check(shell("curl -s \(hdr) \(API)/ping").contains("\"turbo\":true"), "ping tells the extension Turbo is on")
    _ = shell("curl -s \(hdr) '\(API)/ping?turbo=1&blocked=0'")
    check(onMain { TurboManager.shared.chromeApplied }, "the app learns Chrome took the proxy")
    check(shell("curl -s -o /dev/null -w '%{http_code}' \(hdr) -H 'Content-Type: application/json' -d '{\"on\":false}' \(API)/turbo") == "200",
          "the extension can switch Turbo off")
    check(waitFor(5) { !TurboManager.shared.running } && !ud.bool(forKey: "turbo"), "Turbo stops and the setting follows")
    Thread.sleep(forTimeInterval: 1)
    check(!turboListening(), "the proxy's port is free again")
    ud.set(true, forKey: "turbo")
    onMain { TurboManager.shared.update(lines: ["lo0"]) }
    _ = waitFor(10) { TurboManager.shared.running }

    // 11. Quitting mid-download keeps the partial file for next time
    let d = SRV + "/d.bin"
    onMain { _ = DownloadManager.shared.add(url: d) }
    check(waitFor(30) { (DownloadManager.shared.items.first { $0.url == d }?.done ?? 0) > 4 << 20 }, "fourth download starts")
    onMain { DownloadManager.shared.shutdown() }
    check(item(d)?.state == .paused, "quit leaves the download paused")
    check(engines() == 0, "quit stops every engine")
    check(FileManager.default.fileExists(atPath: OUT + "/d.bin.dualdl-part"), "quit keeps the partial file")
    Thread.sleep(forTimeInterval: 1)
    check(!turboListening(), "quit stops the Turbo proxy")

    print(failures == 0 ? "manager: all passed" : "manager: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
