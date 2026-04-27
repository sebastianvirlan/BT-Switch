import Foundation
import Combine

/// User-configurable settings, persisted via UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let destination = "destination"
        static let peripherals = "peripherals"   // comma-separated MAC addresses
        static let token = "token"
        static let port = "port"
    }

    @Published var destination: String {
        didSet { UserDefaults.standard.set(destination, forKey: Keys.destination) }
    }

    /// Comma-separated MAC addresses, e.g. "10:94:BB:B9:73:74,0C:E4:41:21:A6:9B"
    @Published var peripheralsCSV: String {
        didSet { UserDefaults.standard.set(peripheralsCSV, forKey: Keys.peripherals) }
    }

    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Keys.token) }
    }

    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
    }

    /// Parsed, normalised list of MACs (lowercase, colon-separated).
    var peripherals: [String] {
        peripheralsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Self.normalizeMAC($0) }
    }

    private init() {
        let d = UserDefaults.standard
        self.destination = d.string(forKey: Keys.destination) ?? ""
        self.peripheralsCSV = d.string(forKey: Keys.peripherals) ?? ""
        self.token = d.string(forKey: Keys.token) ?? ""
        let savedPort = d.integer(forKey: Keys.port)
        self.port = savedPort > 0 ? savedPort : 52525
    }

    static func normalizeMAC(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    static func isValidMAC(_ s: String) -> Bool {
        let pattern = "^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$"
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else {
            // Fallback to a less-cryptographic source. Should never happen.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
