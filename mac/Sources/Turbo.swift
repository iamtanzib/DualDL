import Foundation

/// Turbo browsing: runs turbo.py (a local HTTPS proxy over every line) while the
/// setting is on. The Chrome extension points Chrome at it; with the app closed,
/// Chrome falls back to browsing directly.
@MainActor
final class TurboManager: ObservableObject {
    static let shared = TurboManager()
    static let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["DUALDL_TURBO_PORT"] ?? "") ?? 51978

    @Published private(set) var running = false
    @Published private(set) var rates: [String: Double] = [:]       // browsing speed per line
    @Published private(set) var capacities: [String: Double] = [:]  // what each line has shown it can do
    @Published private(set) var tunnels = 0
    @Published private(set) var message: String?
    /// Reported by the extension on its check-ins.
    @Published var chromeApplied = false
    @Published var chromeBlocked = false

    private var process: Process?
    private var lines: [String] = []
    private var restarts = 0

    var enabled: Bool { UserDefaults.standard.bool(forKey: "turbo") }
    var totalRate: Double { rates.values.reduce(0, +) }

    /// Starts, restarts (lines changed) or stops the proxy to match the setting.
    func update(lines usable: [String]) {
        guard enabled else { stop(); return }
        if process != nil, usable == lines { return }
        stop()
        start(usable)
    }

    func setEnabled(_ on: Bool, lines usable: [String]) {
        UserDefaults.standard.set(on, forKey: "turbo")
        restarts = 0
        message = nil
        update(lines: usable)
    }

    func stop() {
        process?.terminate()
        process = nil
        running = false
        rates = [:]
        tunnels = 0
    }

    private func start(_ usable: [String]) {
        lines = usable
        var args = ["--port", String(Self.port)]
        if !usable.isEmpty { args += ["-i", usable.joined(separator: ",")] }
        var started: Process?
        started = Engine.run("turbo", args, qos: .userInitiated, onEvent: { [weak self] e in
            guard let self, self.process === started else { return }
            self.handle(e)
        }, onExit: { [weak self] code, tail in
            guard let self, self.process === started else { return }
            self.process = nil
            self.running = false
            self.rates = [:]
            if code != 0, self.message == nil { self.message = tail.isEmpty ? "Turbo stopped (code \(code))" : tail }
            // Crashed or killed while it should run: try again a few times, then leave it off.
            if self.enabled, self.restarts < 5 {
                self.restarts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { self.update(lines: self.lines) }
                }
            }
        })
        process = started
    }

    private func handle(_ e: [String: Any]) {
        func perLine(_ key: String) -> [String: Double] {
            var out: [String: Double] = [:]
            for (k, v) in e["lines"] as? [String: [String: Any]] ?? [:] {
                out[k] = (v[key] as? NSNumber)?.doubleValue ?? 0
            }
            return out
        }
        switch e["event"] as? String {
        case "ready":
            running = true
            restarts = 0
            message = nil
        case "stats":
            let r = perLine("rate")
            if r != rates { rates = r }
            capacities = perLine("capacity")
            tunnels = Int(perLine("active").values.reduce(0, +))
        case "error":
            message = e["message"] as? String
        default:
            break
        }
    }
}
