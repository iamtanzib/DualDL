import AppKit
import SwiftUI
import UserNotifications

@main
struct DualDLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var manager = DownloadManager.shared

    var body: some Scene {
        Window("DualDL", id: "main") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 760, minHeight: 540)
                .onOpenURL { manager.handleOpenURL($0) }
        }
        .defaultSize(width: 880, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Convert Video for Mac & Premiere…") { manager.pickAndConvert() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environmentObject(manager)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DownloadManager.shared.startServer()
        _ = ToolsManager.shared                 // reads tool versions, weekly yt-dlp update
        if WiFiNames.shared.status == .notDetermined { WiFiNames.shared.requestAccess() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Closing the window keeps downloads (and the Chrome link) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, let open = DownloadManager.shared.openMainWindow {
            open()
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DownloadManager.shared.shutdown()
    }
}
