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

    /// Last known number of configured peripherals connected here; nil until
    /// the first Bluetooth read completes. Updated asynchronously so the
    /// main thread never touches IOBluetooth.
    private var connectedHere: Int?
    private var snapshotInFlight = false

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

        // Peripheral list edits change the count immediately.
        settings.$peripheralsCSV
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.connectedHere = nil
                self?.refresh()
            }
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
        guard settings.isConfigured else {
            openSettings()
            return
        }
        coordinator.switchToDestination()
    }

    private func showRightClickMenu() {
        let menu = NSMenu()

        // Header: current peripheral location, then the last switch result.
        for line in statusLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let switchItem = NSMenuItem(
            title: "Switch peripherals to \(displayDestination())",
            action: #selector(menuSwitch),
            keyEquivalent: ""
        )
        switchItem.target = self
        switchItem.isEnabled = !coordinator.isRunning && settings.isConfigured
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Peripheral location is always shown; the last switch result is shown
    /// underneath once there has been one.
    private func statusLines() -> [String] {
        var lines: [String] = []
        let total = settings.peripherals.count
        if total == 0 {
            lines.append("Not configured — open Settings")
        } else if let here = connectedHere {
            lines.append("\(here) of \(total) peripherals here")
        } else {
            lines.append("Checking peripherals…")
        }

        switch coordinator.status {
        case .idle:
            break
        case .running(let phase):
            lines.append("Switching: \(phase)")
        case .success(let at):
            lines.append("Last switch succeeded at \(Self.timeFormatter.string(from: at))")
        case .failure(let msg, let at):
            lines.append("Last switch failed at \(Self.timeFormatter.string(from: at)): \(msg)")
        }
        return lines
    }

    /// Redraw the icon from cached state, then kick off a background
    /// Bluetooth read that redraws again when it completes.
    private func refresh() {
        updateIcon()
        requestSnapshot()
    }

    private func requestSnapshot() {
        let macs = settings.peripherals
        guard !macs.isEmpty, !snapshotInFlight else { return }
        snapshotInFlight = true
        bluetooth.connectedCount(macs) { [weak self] n in
            guard let self = self else { return }
            self.snapshotInFlight = false
            // Ignore stale answers if the list changed meanwhile.
            if self.settings.peripherals == macs {
                self.connectedHere = n
            }
            self.updateIcon()
        }
    }

    /// Refresh the menu bar icon. We use SF Symbols for a clean look.
    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let total = settings.peripherals.count
        let symbolName: String
        let alpha: CGFloat

        if case .running = coordinator.status {
            symbolName = "arrow.triangle.2.circlepath"
            alpha = 1.0
        } else if total == 0 {
            symbolName = "keyboard.badge.ellipsis"
            alpha = 0.5
        } else if let here = connectedHere, here == total {
            symbolName = "keyboard.fill"
            alpha = 1.0
        } else if connectedHere == nil || connectedHere == 0 {
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
        button.toolTip = statusLines().joined(separator: "\n")
    }
}
