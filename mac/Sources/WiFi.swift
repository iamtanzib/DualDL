import AppKit
import CoreLocation
import CoreWLAN

/// The current Wi-Fi link: band, channel, signal, speed.
struct WiFiLink: Equatable {
    var ssid: String?
    var band: String
    var channel: Int
    var width: Int
    var rssi: Int
    var noise: Int
    var rate: Double
}

/// Wi-Fi network names (SSIDs) per interface.
///
/// macOS only tells apps the Wi-Fi name once they have Location access, so this
/// asks for it. The location itself is never read.
@MainActor
final class WiFiNames: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WiFiNames()

    @Published var names: [String: String] = [:]
    @Published var link: WiFiLink?
    @Published var scanning = false
    @Published var scanResult: String?
    @Published var status: CLAuthorizationStatus

    private let location = CLLocationManager()

    var authorized: Bool { status == .authorizedAlways }    // macOS has no "when in use" state

    override init() {
        status = location.authorizationStatus
        super.init()
        location.delegate = self
        refresh()
    }

    /// First time: the system prompt. After a "Don't Allow": the Location Services pane.
    func requestAccess() {
        if status == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else if !authorized,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        var found: [String: String] = [:]
        for wifi in CWWiFiClient.shared().interfaces() ?? [] {
            if let name = wifi.interfaceName, let ssid = wifi.ssid(), !ssid.isEmpty { found[name] = ssid }
        }
        if found != names { names = found }
        let now = Self.currentLink()
        if now != link { link = now }
    }

    static func quality(_ rssi: Int) -> String {
        rssi >= -60 ? "good" : rssi >= -70 ? "fair" : "weak"
    }

    private static func band(_ c: CWChannel) -> String {
        switch c.channelBand {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return "Wi-Fi"
        }
    }

    private static func currentLink() -> WiFiLink? {
        guard let i = CWWiFiClient.shared().interface(), let ch = i.wlanChannel() else { return nil }
        let width: Int
        switch ch.channelWidth {
        case .width20MHz: width = 20
        case .width40MHz: width = 40
        case .width80MHz: width = 80
        case .width160MHz: width = 160
        default: width = 0
        }
        return WiFiLink(ssid: i.ssid(), band: band(ch), channel: ch.channelNumber, width: width,
                        rssi: i.rssiValue(), noise: i.noiseMeasurement(), rate: i.transmitRate())
    }

    /// Scans for a 5/6 GHz version of the current network (same name, or a "…5G" sibling).
    /// Read-only: it never joins anything; the user switches from the Wi-Fi menu.
    func findFasterBand() {
        guard let current = link, let ssid = current.ssid else {
            scanResult = "Allow Location for DualDL first (it's how macOS shares Wi-Fi names)."
            requestAccess()
            return
        }
        scanning = true
        scanResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var msg: String
            do {
                let nets = try CWWiFiClient.shared().interface()?.scanForNetworks(withName: nil) ?? []
                let base = ssid.lowercased()
                let fast = nets.filter { n in
                    guard let s = n.ssid?.lowercased(), let ch = n.wlanChannel,
                          ch.channelBand == .band5GHz || ch.channelBand == .band6GHz else { return false }
                    let sibling = s.hasPrefix(base) && (s.contains("5g") || s.contains("6g") || s.contains("5 g"))
                    return s == base || sibling
                }.sorted { $0.rssiValue > $1.rssiValue }
                if let best = fast.first, let name = best.ssid, let ch = best.wlanChannel {
                    let q = Self.quality(best.rssiValue)
                    if current.band != "2.4 GHz" {
                        msg = "You're already on \(current.band)."
                    } else if name.lowercased() == base {
                        msg = "Your router also sends “\(name)” on \(Self.band(ch)) (signal \(best.rssiValue) dBm, \(q)). "
                            + "macOS picks the band itself; it stays on 2.4 GHz when 5 GHz is too weak where you sit. "
                            + "Moving closer to the router usually makes it switch."
                    } else {
                        msg = "“\(name)” is your router's \(Self.band(ch)) network (signal \(best.rssiValue) dBm, \(q)). "
                            + "Join it from the Wi-Fi menu in the menu bar (usually the same password) for much faster browsing."
                    }
                } else {
                    msg = "No 5 GHz version of “\(ssid)” is in range. If your router supports 5 GHz, it may be "
                        + "switched off in its settings (often at 192.168.0.1)."
                }
            } catch {
                msg = "Couldn't scan: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    self.scanResult = msg
                    self.refresh()
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.status = st
                self.refresh()
            }
        }
    }
}
