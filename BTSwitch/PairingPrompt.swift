import AppKit

/// The "… wants to pair" Allow/Deny alert shown on the Mac being paired with.
final class PairingPrompt {
    private var alert: NSAlert?
    private var dismissed = false   // main thread only

    /// Shows the alert asynchronously on main. `decide` is called with the
    /// user's choice (false if dismissed). Returns a dismiss closure that
    /// is safe to call from any thread, before or after the alert appears.
    static func show(_ request: NetworkServer.PairingRequest, decide: @escaping (Bool) -> Void) -> () -> Void {
        let prompt = PairingPrompt()
        DispatchQueue.main.async { prompt.present(request, decide: decide) }
        return { DispatchQueue.main.async { prompt.dismiss() } }
    }

    private func present(_ request: NetworkServer.PairingRequest, decide: @escaping (Bool) -> Void) {
        guard !dismissed else { return }

        let alert = NSAlert()
        alert.messageText = "“\(request.name)” wants to pair with BTSwitch"
        var info = """
        Allow only if “\(request.name)” shows this code. Once paired, it can move your \
        keyboard, mouse and trackpad to and from this Mac.

        Request from \(request.address)
        """
        if let old = request.replacing {
            info += "\n\nThis replaces the pairing with “\(old)”."
        }
        alert.informativeText = info

        let code = NSTextField(labelWithString: Pairing.formatCode(request.code))
        code.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        code.alignment = .center
        code.frame = NSRect(x: 0, y: 0, width: 260, height: 46)
        alert.accessoryView = code

        // Allow is the default (Return) so a Mac with only a USB-connected
        // keyboard can approve; Escape denies.
        alert.addButton(withTitle: "Allow")
        let deny = alert.addButton(withTitle: "Deny")
        deny.keyEquivalent = "\u{1b}"

        self.alert = alert
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        let response = alert.runModal()
        self.alert = nil
        decide(response == .alertFirstButtonReturn)
    }

    private func dismiss() {
        dismissed = true
        guard let alert = alert, NSApp.modalWindow === alert.window else { return }
        NSApp.abortModal()
    }
}
