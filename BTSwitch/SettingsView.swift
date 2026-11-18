import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logger: AppLogger
    @EnvironmentObject var coordinator: SwitchCoordinator
    @EnvironmentObject var server: NetworkServer
    @EnvironmentObject var directory: PeerDirectory
    @EnvironmentObject var pairingController: PairingController
    @EnvironmentObject var pairing: PairingStore

    @State private var testStatus: (ok: Bool, message: String)?
    @State private var testing = false
    @State private var manualAddress = ""
    @State private var confirmUnpair = false
    @State private var devices: [BluetoothController.PairedDevice] = []
    @State private var showAllDevices = false

    var body: some View {
        TabView {
            pairingTab
                .tabItem { Label("Pairing", systemImage: "link") }
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            logTab
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .padding(16)
    }

    // MARK: - Pairing tab

    private var pairingTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let peer = pairing.peer {
                pairedView(peer)
            } else {
                unpairedView
            }
            pairingProgress
            Spacer()
        }
    }

    private func pairedView(_ peer: PairedPeer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired Mac").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.name).font(.title3)
                    Text(reachability(of: peer)).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack {
                Button(action: testConnection) {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "Testing…" : "Test Connection")
                }
                .disabled(testing)
                Spacer()
                Button("Unpair…") { confirmUnpair = true }
            }
            if let s = testStatus {
                Label(s.message, systemImage: s.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.callout).foregroundColor(s.ok ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("Click the menu bar icon to move your peripherals to \(peer.name). Pairing with another Mac replaces this one.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)
            nearbyList(excluding: peer.id, title: "Pair with a different Mac")
        }
        .alert("Unpair from \(peer.name)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) {
                testStatus = nil
                coordinator.unpair()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Both Macs forget each other. You'll need to pair again to switch peripherals.")
        }
    }

    private var unpairedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair with your other Mac").font(.headline)
            Text("Open BTSwitch on the other Mac too. Pick it below, then click Allow on the other Mac once you've checked that both show the same code.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            nearbyList(excluding: nil, title: nil)
        }
    }

    private func nearbyList(excluding: String?, title: String?) -> some View {
        let others = directory.peers.filter { $0.id != excluding }
        return VStack(alignment: .leading, spacing: 8) {
            if let title = title { Text(title).font(.headline) }
            if others.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Macs running BTSwitch on this network…")
                        .font(.callout).foregroundColor(.secondary)
                }
            } else {
                ForEach(others) { mac in
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(mac.name)
                        Spacer()
                        Button("Pair") { pairingController.pair(with: mac) }
                            .disabled(pairingController.state.isBusy)
                    }
                }
            }

            DisclosureGroup("Not listed? Pair by address") {
                HStack {
                    TextField("192.168.1.42 or other-mac.local", text: $manualAddress)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit(pairByAddress)
                    Button("Pair", action: pairByAddress)
                        .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
                                  || pairingController.state.isBusy)
                }
                .padding(.top, 4)
                Text("Both Macs must use the same listener port (General tab).")
                    .font(.caption).foregroundColor(.secondary)
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var pairingProgress: some View {
        switch pairingController.state {
        case .idle:
            EmptyView()
        case .connecting(let name):
            progressBox {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Contacting \(name)…")
                    Spacer()
                    Button("Cancel") { pairingController.cancel() }
                }
            }
        case .awaitingApproval(let name, let code):
            progressBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to click Allow on \(name)…")
                        Spacer()
                        Button("Cancel") { pairingController.cancel() }
                    }
                    Text(Pairing.formatCode(code))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                    Text("\(name) must show this same code. If it shows a different code, click Deny there.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .paired(let name):
            progressBox {
                HStack {
                    Label("Paired with \(name)", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                    Spacer()
                    Button("OK") { pairingController.reset() }
                }
            }
        case .failed(let message):
            progressBox {
                HStack(alignment: .top) {
                    Label(message, systemImage: "xmark.octagon.fill").foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    Button("OK") { pairingController.reset() }
                }
            }
        }
    }

    private func progressBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
    }

    private func reachability(of peer: PairedPeer) -> String {
        if directory.peers.contains(where: { $0.id == peer.id }) {
            return "Found on this network"
        }
        if let addr = peer.address {
            return "Not visible via Bonjour; will try \(addr)"
        }
        return "Not visible on this network right now"
    }

    private func pairByAddress() {
        let addr = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty, !pairingController.state.isBusy else { return }
        pairingController.pair(address: addr, port: settings.port)
    }

    // MARK: - General tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            peripheralPicker

            Divider().padding(.vertical, 2)

            clipboardSettings

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Listener Port").font(.headline)
                HStack {
                    TextField("52525", value: $settings.port, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("1–65535; restart app after changing")
                        .font(.caption).foregroundColor(.secondary)
                }
                listenerStatus
            }

            Spacer()
        }
    }

    // MARK: - Peripheral picker

    /// A row in the picker: a device paired with this Mac, or a selected one
    /// that's currently paired with the other Mac (so not listed here).
    private struct DeviceRow: Identifiable {
        let address: String
        let name: String
        let kind: BluetoothController.PairedDevice.Kind
        let status: String
        var id: String { address }
    }

    private var deviceRows: [DeviceRow] {
        var rows = devices
            .filter { showAllDevices || $0.kind.isInputDevice || settings.isSelected($0.address) }
            .map { DeviceRow(address: $0.address, name: $0.name, kind: $0.kind,
                             status: $0.isConnected ? "Connected to this Mac" : "Paired, not connected") }
        let listed = Set(devices.map(\.address))
        for mac in settings.peripherals where !listed.contains(mac) {
            let name = settings.peripheralNames[mac] ?? mac
            rows.append(DeviceRow(address: mac, name: name, kind: Self.guessKind(name),
                                  status: "Not paired with this Mac right now (probably on the other Mac)"))
        }
        return rows
    }

    private static func guessKind(_ name: String) -> BluetoothController.PairedDevice.Kind {
        let n = name.lowercased()
        if n.contains("trackpad") { return .trackpad }
        if n.contains("keyboard") { return .keyboard }
        if n.contains("mouse") { return .mouse }
        return .other
    }

    private var peripheralPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Peripherals to switch").font(.headline)
                Spacer()
                Button {
                    refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh the list of Bluetooth devices")
            }

            let rows = deviceRows
            if rows.isEmpty {
                Text("No Bluetooth keyboards, mice or trackpads are paired with this Mac. Pair them in System Settings → Bluetooth first.")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Toggle(isOn: Binding(
                            get: { settings.isSelected(row.address) },
                            set: { settings.setSelected(row.address, $0, name: row.name) }
                        )) {
                            HStack(spacing: 10) {
                                Image(systemName: row.kind.symbol)
                                    .frame(width: 22)
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.name)
                                    Text(row.status)
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }

            HStack {
                Toggle("Show all Bluetooth devices", isOn: $showAllDevices)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                let n = settings.peripherals.count
                Text(n == 0 ? "None selected" : "\(n) selected")
                    .font(.caption).foregroundColor(.secondary)
            }
            Text("Choose them on one Mac: the other Mac picks up the same list the first time you switch.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refreshDevices)
    }

    private func refreshDevices() {
        BTServices.shared.bluetooth.pairedDevices { list in
            devices = list
            settings.rememberNames(list)
        }
    }

    // MARK: - Clipboard

    private var clipboardSettings: some View {
        let other = pairing.peer?.name ?? "the other Mac"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Clipboard").font(.headline)
            Toggle("Send copied text to \(other) when switching to it", isOn: $settings.sendClipboard)
                .toggleStyle(.checkbox)
            Toggle("Accept copied text from \(other)", isOn: $settings.acceptClipboard)
                .toggleStyle(.checkbox)
            Text("Text only, up to \(BTProtocol.maxClipboardBytes / 1024) KB, encrypted with the pairing key. Passwords copied from password managers are never sent. Both Macs must agree: one sends, the other accepts.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether this Mac can be reached by the other one.
    @ViewBuilder private var listenerStatus: some View {
        switch server.state {
        case .starting:
            Label("Starting listener…", systemImage: "circle.dotted")
                .font(.caption).foregroundColor(.secondary)
        case .listening(let port):
            Label("\(AppInfo.computerName) is listening on port \(port)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(.green)
        case .failed(let why):
            Label("Not listening: \(why)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Log tab

    private var logTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logger.formattedDump(), forType: .string)
                }
                Button("Clear") { logger.clear() }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logger.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(entry.level)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(color(for: entry.level))
                                    .frame(width: 50, alignment: .leading)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .onChange(of: logger.entries.count) { _ in
                    if let last = logger.entries.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func color(for level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN":  return .orange
        default:      return .secondary
        }
    }

    // MARK: - Test connection

    private func testConnection() {
        testing = true
        testStatus = nil
        coordinator.testConnection { ok, message in
            testing = false
            testStatus = (ok, message)
        }
    }
}
