import Foundation
import Combine
import SystemConfiguration

enum AppInfo {
    static let bundleID = Bundle.main.bundleIdentifier ?? "io.github.sebastianvirlan.btswitch"
    /// Bundle ID used by earlier builds; settings are migrated from it once.
    static let legacyBundleID = "com.user.btswitch"

    /// Random per-install ID, sent in ping replies so a Mac can tell when
    /// its destination address actually points back at itself.
    static let instanceID: String = {
        let key = "instanceID"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = String(BTProtocol.makeNonce().prefix(12))
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// The computer name from System Settings → General → Sharing.
    /// (Host.current().localizedName can block on DNS, so avoid it.)
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "this Mac"
    }
}

/// User-configurable settings (peripherals, port), persisted in
/// UserDefaults. The pairing with the other Mac lives in PairingStore.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let peripherals = "peripherals"   // comma-separated MAC addresses
        static let port = "port"
        static let peripheralNames = "peripheralNames"
        static let sendClipboard = "sendClipboard"
        static let acceptClipboard = "acceptClipboard"
        // Removed in v3 (replaced by pairing); cleaned up on launch.
        static let legacyDestination = "destination"
        static let legacyToken = "token"
    }

    /// Comma-separated MAC addresses, e.g. "10:94:BB:B9:73:74,0C:E4:41:21:A6:9B"
    @Published var peripheralsCSV: String {
        didSet { UserDefaults.standard.set(peripheralsCSV, forKey: Keys.peripherals) }
    }

    /// Always within 1...65535. Out-of-range input reverts to the previous value.
    @Published var port: Int {
        didSet {
            if BTProtocol.port(from: port) == nil {
                port = BTProtocol.port(from: oldValue) != nil ? oldValue : BTProtocol.defaultPort
                return
            }
            UserDefaults.standard.set(port, forKey: Keys.port)
        }
    }

    /// Display names for selected peripherals, so they can still be listed
    /// while they're paired with the other Mac (and so absent from this
    /// Mac's Bluetooth list).
    @Published private(set) var peripheralNames: [String: String] {
        didSet { UserDefaults.standard.set(peripheralNames, forKey: Keys.peripheralNames) }
    }

    /// Send this Mac's clipboard text to the other Mac when switching away.
    @Published var sendClipboard: Bool {
        didSet { UserDefaults.standard.set(sendClipboard, forKey: Keys.sendClipboard) }
    }

    /// Put clipboard text received from the paired Mac on this Mac's clipboard.
    @Published var acceptClipboard: Bool {
        didSet { UserDefaults.standard.set(acceptClipboard, forKey: Keys.acceptClipboard) }
    }

    /// Parsed, normalised list of valid MACs (lowercase, colon-separated).
    var peripherals: [String] { MAC.parseList(peripheralsCSV) }

    func isSelected(_ mac: String) -> Bool {
        peripherals.contains(MAC.normalize(mac))
    }

    func setSelected(_ mac: String, _ selected: Bool, name: String?) {
        let mac = MAC.normalize(mac)
        var list = peripherals
        if selected, !list.contains(mac) {
            list.append(mac)
        } else if !selected {
            list.removeAll { $0 == mac }
        }
        peripheralsCSV = list.joined(separator: ",")
        if selected, let name = name { peripheralNames[mac] = name }
    }

    /// Remembers names of devices that are currently visible.
    func rememberNames(_ devices: [BluetoothController.PairedDevice]) {
        var names = peripheralNames
        for d in devices where isSelected(d.address) { names[d.address] = d.name }
        if names != peripheralNames { peripheralNames = names }
    }

    /// Used when the other Mac sends peripherals and none are chosen here,
    /// so they only have to be picked on one Mac.
    func adoptPeripheralsIfNoneSelected(_ macs: [String]) -> Bool {
        guard peripherals.isEmpty, !macs.isEmpty else { return false }
        peripheralsCSV = macs.joined(separator: ",")
        return true
    }

    private init() {
        Self.migrateLegacyDefaults()
        Self.removeSharedToken()
        let d = UserDefaults.standard
        self.peripheralsCSV = d.string(forKey: Keys.peripherals) ?? ""
        self.peripheralNames = (d.dictionary(forKey: Keys.peripheralNames) as? [String: String]) ?? [:]
        // Both off unless the user opts in.
        self.sendClipboard = d.bool(forKey: Keys.sendClipboard)
        self.acceptClipboard = d.bool(forKey: Keys.acceptClipboard)

        let savedPort = d.integer(forKey: Keys.port)
        // Sanitise here too: an out-of-range value saved by an older build
        // used to crash the app on every launch.
        self.port = BTProtocol.port(from: savedPort) != nil ? savedPort : BTProtocol.defaultPort
    }

    /// Copies peripherals/port from the old bundle ID's preferences if this
    /// bundle ID has none yet.
    private static func migrateLegacyDefaults() {
        guard AppInfo.bundleID != AppInfo.legacyBundleID,
              let legacy = UserDefaults(suiteName: AppInfo.legacyBundleID) else { return }
        let current = UserDefaults.standard
        for key in [Keys.peripherals, Keys.port] where current.object(forKey: key) == nil {
            if let v = legacy.object(forKey: key) { current.set(v, forKey: key) }
        }
    }

    /// v3 replaced the shared token and typed destination with pairing.
    /// Delete the old secret wherever earlier builds kept it.
    private static func removeSharedToken() {
        Keychain.delete(account: "shared-token")
        for d in [UserDefaults.standard, UserDefaults(suiteName: AppInfo.legacyBundleID)].compactMap({ $0 }) {
            d.removeObject(forKey: Keys.legacyToken)
            d.removeObject(forKey: Keys.legacyDestination)
        }
    }
}
