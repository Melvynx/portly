import AppKit
import PortlyCore
import SwiftUI

@main
struct PortlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var supervisor = Supervisor.shared

    var body: some Scene {
        Window("Portly", id: WindowOpener.mainWindowID) {
            MainView()
                .environmentObject(supervisor)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { WindowOpener.registerCurrentWindow() }
        }
        .defaultSize(width: 1080, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(supervisor)
        } label: {
            MenuBarLabel(supervisor: supervisor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar glyph. Filled when something is running, badged when something
/// needs attention.
private struct MenuBarLabel: View {
    @ObservedObject var supervisor: Supervisor

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Portly")
    }

    private var symbol: String {
        if supervisor.hasProblem { return "bolt.horizontal.circle.fill" }
        return supervisor.runningCount > 0 ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var control: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PortlyPaths.ensureDirectories()
        Notifications.requestAuthorization()
        let server = ControlServer(supervisor: Supervisor.shared, port: Supervisor.shared.settings.apiPort)
        server.start()
        control = server
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The app is the supervisor: quitting takes every server down with it.
        Supervisor.shared.terminateEverythingSynchronously()
        control?.stop()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Bridges "open the window" requests coming from the menu bar and the control API.
///
/// The opener closure is captured from the menu bar scene, which is always alive,
/// so the window can be recreated even after it was closed.
enum WindowOpener {
    static let mainWindowID = "portly.main"
    static var opener: (() -> Void)?

    static func registerCurrentWindow() {}

    static func openMainWindow() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(mainWindowID) == true }) {
                window.makeKeyAndOrderFront(nil)
                return
            }
            opener?()
        }
    }
}
