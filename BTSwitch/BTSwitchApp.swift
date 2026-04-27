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
        self.bluetooth = bt
        self.coordinator = SwitchCoordinator(
            settings: AppSettings.shared,
            bluetooth: bt,
            logger: AppLogger.shared
        )
        self.server = NetworkServer(
            settings: AppSettings.shared,
            bluetooth: bt,
            logger: AppLogger.shared
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

        logger.info("BTSwitch starting up")

        if settings.token.isEmpty {
            settings.token = AppSettings.generateToken()
            logger.info("generated new token")
        }

        do {
            try services.server.start()
            logger.info("listener started on port \(settings.port)")
        } catch {
            logger.error("listener failed: \(error.localizedDescription)")
        }

        menuBar = MenuBarController(
            settings: settings,
            coordinator: services.coordinator,
            bluetooth: services.bluetooth,
            logger: logger,
            openSettings: { [weak self] in self?.openSettings() }
        )
        menuBar.install()
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