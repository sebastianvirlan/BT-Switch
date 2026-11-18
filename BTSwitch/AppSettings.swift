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

/// User-configurable settings. Destination, peripherals and port live in
/// UserDefaults; the shared token lives in the Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let destination = "destination"
        static let peripherals = "peripherals"   // comma-separated MAC addresses
        static let token = "token"               // legacy (pre-Keychain) location only
        static let port = "port"
    }

    @Published var destination: String {
        didSet { UserDefaults.standard.set(destination, forKey: Keys.destination) }
    }

    /// Comma-separated MAC addresses, e.g. "10:94:BB:B9:73:74,0C:E4:41:21:A6:9B"
    @Published var peripheralsCSV: String {
        didSet { UserDefaults.standard.set(peripheralsCSV, forKey: Keys.peripherals) }
    }

    /// Always normalised: whitespace stripped, lowercase.
    @Published var token: String {
        didSet {
            let normalized = BTProtocol.normalizeToken(token)
            if normalized != token {
                // Assigning inside didSet doesn't re-run didSet, so carry on
                // and persist the clean value below.
                token = normalized
            }
            guard token != oldValue else { return }
            if !Keychain.writeToken(token) {
                AppLogger.shared.error("could not save token to Keychain")
            }
        }
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

    /// Parsed, normalised list of valid MACs (lowercase, colon-separated).
    var peripherals: [String] { MAC.parseList(peripheralsCSV) }

    var isConfigured: Bool {
        !destination.trimmingCharacters(in: .whitespaces).isEmpty && !peripherals.isEmpty && !token.isEmpty
    }

    private init() {
        Self.migrateLegacyDefaults()
        let d = UserDefaults.standard
        self.destination = d.string(forKey: Keys.destination) ?? ""
        self.peripheralsCSV = d.string(forKey: Keys.peripherals) ?? ""

        let savedPort = d.integer(forKey: Keys.port)
        // Sanitise here too: an out-of-range value saved by an older build
        // used to crash the app on every launch.
        self.port = BTProtocol.port(from: savedPort) != nil ? savedPort : BTProtocol.defaultPort

        let stored = Self.loadTokenMigratingFromDefaults()
        let clean = BTProtocol.normalizeToken(stored)
        if clean != stored {
            // Earlier builds saved pasted whitespace verbatim, which caused
            // spurious "token mismatch" errors.
            Keychain.writeToken(clean)
        }
        self.token = clean
    }

    var tokenFingerprint: String { BTProtocol.fingerprint(token) }

    /// Reads the token from the Keychain, moving it out of UserDefaults
    /// (current or legacy domain) the first time.
    private static func loadTokenMigratingFromDefaults() -> String {
        if let t = Keychain.readToken(), !t.isEmpty { return t }
        let domains = [UserDefaults.standard, UserDefaults(suiteName: AppInfo.legacyBundleID)].compactMap { $0 }
        for d in domains {
            if let t = d.string(forKey: Keys.token), !t.isEmpty {
                if Keychain.writeToken(t) {
                    d.removeObject(forKey: Keys.token)
                }
                return t
            }
        }
        return ""
    }

    /// Copies destination/peripherals/port from the old bundle ID's
    /// preferences if this bundle ID has none yet.
    private static func migrateLegacyDefaults() {
        guard AppInfo.bundleID != AppInfo.legacyBundleID,
              let legacy = UserDefaults(suiteName: AppInfo.legacyBundleID) else { return }
        let current = UserDefaults.standard
        for key in [Keys.destination, Keys.peripherals, Keys.port]
        where current.object(forKey: key) == nil {
            if let v = legacy.object(forKey: key) { current.set(v, forKey: key) }
        }
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else {
            // Fallback to a less-cryptographic source. Should never happen.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return BTProtocol.hex(bytes)
    }
}
