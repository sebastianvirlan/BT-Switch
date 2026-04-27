import AppKit
import Combine

/// Menu bar icon. Left-click = switch. Right-click = menu (Settings, Quit, etc.).
final class MenuBarController: NSObject {
    private let settings: AppSettings
    private let coordinator: SwitchCoordinator
    private let bluetooth: BluetoothController
    private let logger: AppLogger
    private let openSettings: () -> Void

    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var statusRefreshTimer: Timer?

    init(settings: AppSettings,
         coordinator: SwitchCoordinator,
         bluetooth: BluetoothController,
         logger: AppLogger,
         openSettings: @escaping () -> Void) {
        self.settings = settings
        self.coordinator = coordinator
        self.bluetooth = bluetooth
        self.logger = logger
        self.openSettings = openSettings
        super.init()
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Observe coordinator status to update icon during a switch.
        coordinator.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Periodic refresh of the connected/disconnected indicator.
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        statusRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        refresh()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            handleLeftClick()
        }
    }

    private func handleLeftClick() {
        guard !coordinator.isRunning else {
            // If the user clicks during a switch, just show the menu.
            showRightClickMenu()
            return
        }
        if settings.destination.isEmpty || settings.peripherals.isEmpty || settings.token.isEmpty {
            // Not configured yet — open settings.
            openSettings()
            return
        }
        coordinator.switchToDestination()
    }

    private func showRightClickMenu() {
        let menu = NSMenu()

        // Header: status line.
        let header = NSMenuItem(title: currentStatusText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Switch action.
        let switchItem = NSMenuItem(
            title: "Switch peripherals to \(displayDestination())",
            action: #selector(menuSwitch),
            keyEquivalent: ""
        )
        switchItem.target = self
        switchItem.isEnabled = !coordinator.isRunning
            && !settings.destination.isEmpty
            && !settings.peripherals.isEmpty
            && !settings.token.isEmpty
        menu.addItem(switchItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit BTSwitch", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // detach so left-click works as switch next time
    }

    @objc private func menuSwitch() {
        coordinator.switchToDestination()
    }

    @objc private func menuSettings() {
        openSettings()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    private func displayDestination() -> String {
        let s = settings.destination.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "(unset)" : s
    }

    private func currentStatusText() -> String {
        switch coordinator.status {
        case .running(let phase):
            return "Switching: \(phase)"
        case .failure(let msg):
            return "Last switch failed: \(msg)"
        case .success:
            return "Last switch: success"
        case .idle:
            // Show how many peripherals are here right now.
            let macs = settings.peripherals
            if macs.isEmpty { return "Not configured — open Settings" }
            let here = macs.filter { bluetooth.isConnected($0) }.count
            return "\(here) of \(macs.count) peripherals here"
        }
    }

    /// Refresh the menu bar icon. We use SF Symbols for a clean look.
    private func refresh() {
        guard let button = statusItem?.button else { return }

        let macs = settings.peripherals
        let connectedHere = macs.filter { bluetooth.isConnected($0) }.count

        let symbolName: String
        let alpha: CGFloat

        if case .running = coordinator.status {
            symbolName = "arrow.triangle.2.circlepath"
            alpha = 1.0
        } else if macs.isEmpty {
            symbolName = "keyboard.badge.ellipsis"
            alpha = 0.5
        } else if connectedHere == macs.count {
            symbolName = "keyboard.fill"
            alpha = 1.0
        } else if connectedHere == 0 {
            symbolName = "keyboard"
            alpha = 0.6
        } else {
            symbolName = "keyboard.badge.eye"
            alpha = 0.85
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "BTSwitch")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        button.image = img
        button.alphaValue = alpha
        button.toolTip = currentStatusText()
    }
}
