import SwiftUI
import AppKit

@main
struct BTSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty Settings scene - satisfies App's Scene requirement without
        // producing any UI. Our real menu bar icon and settings window are
        // managed manually by the AppDelegate.
        Settings { EmptyView() }
    }
}

final class BTServices {
    static let shared = BTServices()
    let bluetooth: BluetoothController
    let coordinator: SwitchCoordinator
    let server: NetworkServer

    private init() {
        let bt = BluetoothController()
        // Shared so a local switch and an incoming CONNECT never overlap.
        let lock = SwitchLock()
        self.bluetooth = bt
        self.coordinator = SwitchCoordinator(
            settings: AppSettings.shared,
            bluetooth: bt,
            logger: AppLogger.shared,
            switchLock: lock
        )
        self.server = NetworkServer(
            settings: AppSettings.shared,
            bluetooth: bt,
            logger: AppLogger.shared,
            switchLock: lock
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logger = AppLogger.shared
        let settings = AppSettings.shared
        let services = BTServices.shared

        logger.info("BTSwitch starting up (\(Bundle.main.bundlePath))")

        guard resolveOtherInstances() else { return }

        if settings.token.isEmpty {
            settings.token = AppSettings.generateToken()
            logger.info("generated new token")
        }

        services.server.start()

        menuBar = MenuBarController(
            settings: settings,
            coordinator: services.coordinator,
            server: services.server,
            bluetooth: services.bluetooth,
            logger: logger,
            openSettings: { [weak self] in self?.openSettings() }
        )
        menuBar.install()
    }

    /// Only one copy can hold the listener port; a second one would sit in
    /// the menu bar unreachable while the first answers requests with
    /// whatever token it loaded at launch. Returns false if this copy is
    /// quitting.
    private func resolveOtherInstances() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = Set([AppInfo.bundleID, AppInfo.legacyBundleID])
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return true }

        let paths = others.map { $0.bundleURL?.path ?? "pid \($0.processIdentifier)" }
        AppLogger.shared.warn("another BTSwitch is running: \(paths.joined(separator: ", "))")

        let alert = NSAlert()
        alert.messageText = "Another copy of BTSwitch is already running"
        alert.informativeText = """
        Running copy:
        \(paths.joined(separator: "\n"))

        This copy:
        \(Bundle.main.bundlePath)

        Only one copy can listen for the other Mac.
        """
        alert.addButton(withTitle: "Quit Other Copy")
        alert.addButton(withTitle: "Quit This Copy")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return false
        }

        others.forEach { $0.terminate() }
        // Wait for them to exit so the port is free before we bind it.
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if others.contains(where: { !$0.isTerminated }) {
            AppLogger.shared.error("the other copy did not quit; this copy may not be able to listen")
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        BTServices.shared.server.stop()
        AppLogger.shared.info("BTSwitch shutting down")
    }

    func openSettings() {
        // If the window exists, just bring it forward.
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        // Build a brand new window hosting our SwiftUI SettingsView.
        let view = SettingsView()
            .environmentObject(AppSettings.shared)
            .environmentObject(AppLogger.shared)
            .environmentObject(BTServices.shared.coordinator)
            .environmentObject(BTServices.shared.server)
            .frame(width: 540, height: 580)

        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "BTSwitch Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 540, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === settingsWindow {
            settingsWindow = nil
        }
    }
}