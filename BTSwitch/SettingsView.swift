import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logger: AppLogger
    @EnvironmentObject var coordinator: SwitchCoordinator
    @EnvironmentObject var server: NetworkServer

    @State private var testStatus: String?
    @State private var testing = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            tokenTab
                .tabItem { Label("Token", systemImage: "key") }
            logTab
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .padding(16)
    }

    // MARK: - General tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination Mac (hostname or IP)").font(.headline)
                TextField("192.168.1.42 or other-mac.local", text: $settings.destination)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                Text("This is the *other* Mac. Use its IP for reliability.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Peripherals (comma-separated MAC addresses)").font(.headline)
                TextField("10:94:BB:B9:73:74,0C:E4:41:21:A6:9B", text: $settings.peripheralsCSV)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                let parsed = settings.peripherals
                let invalid = MAC.invalidEntries(settings.peripheralsCSV)
                if !invalid.isEmpty {
                    Text("Invalid MAC: \(invalid.joined(separator: ", "))")
                        .font(.caption).foregroundColor(.red)
                } else if !parsed.isEmpty {
                    Text("\(parsed.count) peripheral\(parsed.count == 1 ? "" : "s") configured")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

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

            Divider().padding(.vertical, 4)

            HStack {
                Button(action: testConnection) {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "Testing…" : "Test Connection")
                }
                .disabled(testing || settings.destination.isEmpty || settings.token.isEmpty)
                Spacer()
            }
            if let s = testStatus {
                Text(s).font(.callout).foregroundColor(s.hasPrefix("✓") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer()
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

    // MARK: - Token tab

    private var tokenTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shared Token").font(.headline)
            Text("Both Macs must use the same token. Copy this Mac's token to the other Mac, or paste the other Mac's token here.")
                .font(.caption).foregroundColor(.secondary)

            HStack {
                TextField("token", text: $settings.token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(settings.token, forType: .string)
                }
                .disabled(settings.token.isEmpty)
            }

            HStack(spacing: 6) {
                Text("Fingerprint:").font(.callout)
                Text(settings.tokenFingerprint)
                    .font(.system(.callout, design: .monospaced)).bold()
                    .textSelection(.enabled)
                Text("— must be the same on both Macs")
                    .font(.caption).foregroundColor(.secondary)
            }
            if !settings.token.isEmpty && !BTProtocol.isValidToken(settings.token) {
                Text("This doesn't look like a BTSwitch token (32 hex characters). Copy it again with the Copy button on the other Mac.")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Generate New Token") {
                    settings.token = AppSettings.generateToken()
                }
                Spacer()
                Text("⚠ Generating a new token will require updating the other Mac too")
                    .font(.caption).foregroundColor(.orange)
            }

            Divider().padding(.vertical, 4)

            Text("How tokens work")
                .font(.headline)
            Text("""
The token is a 32-character secret that both Macs use to sign \
requests. Pick one Mac, copy its token, paste it on the other Mac. The same \
token is used for incoming and outgoing requests, so bidirectional \
switching works with one token. The token itself is never sent over the \
network, and it is stored in your Keychain.
""")
            .font(.callout).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()
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
        let dest = settings.destination
        let token = settings.token
        let port = settings.port
        testing = true
        testStatus = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let r = NetworkClient.send(host: dest, port: port, command: "PING", token: token, timeout: 5)
            DispatchQueue.main.async {
                self.testing = false
                switch r {
                case .success(let s):
                    if let pong = PingReply(s) {
                        if pong.instanceID == AppInfo.instanceID {
                            self.testStatus = "✗ \(dest) is this Mac; enter the other Mac's address"
                        } else if let name = pong.name {
                            self.testStatus = "✓ reachable: \(name), tokens match"
                        } else {
                            self.testStatus = "✓ \(dest) is reachable, tokens match"
                        }
                    } else if BTProtocol.errorCode(in: s) == "busy" {
                        // Auth passed; the other Mac is just mid-switch.
                        self.testStatus = "✓ \(dest) is reachable, tokens match (it's switching right now)"
                    } else {
                        self.testStatus = "✗ \(BTProtocol.describe(response: s, localToken: token))"
                    }
                case .failure(let e):
                    self.testStatus = "✗ \(e)"
                }
            }
        }
    }
}
