import Foundation
import CryptoKit

// Pure, dependency-free logic shared by the client, server and settings.
// Nothing in this file touches AppKit, IOBluetooth or the network, so it is
// compiled into the test runner as-is (see test.sh).

// MARK: - Wire protocol

/// BT-SWITCH/2 wire protocol (line-delimited UTF-8, one request per TCP connection):
///
///     line 1: BT-SWITCH/2
///     line 2: AUTH <unix_timestamp> <nonce_hex> <hmac_hex>
///     line 3: <command>
///
/// `hmac_hex` = hex(HMAC-SHA256(key: token, message: "<timestamp>\n<nonce>\n<command>")).
/// The token itself never crosses the network. Requests older/newer than
/// `maxClockSkew` are rejected, and each nonce is accepted only once, so a
/// captured request cannot be replayed.
///
/// Commands:
///     PING                       -> "OK pong" (or "ERR busy" while a switch is running here)
///     CONNECT <mac1>,<mac2>,...  -> "OK <json [PeripheralReport]>"
///     VERIFY  <mac1>,<mac2>,...  -> "OK <json [PeripheralReport]>"
///
/// Errors are "ERR <code>"; see `BTProtocol.describe(errorCode:)`.
enum BTProtocol {
    static let version = "BT-SWITCH/2"
    static let legacyVersions: Set<String> = ["BT-SWITCH/1"]
    static let maxClockSkew: TimeInterval = 60
    static let maxRequestBytes = 4096
    static let defaultPort = 52525

    // MARK: Framing

    /// Returns the three request lines once all three are newline-terminated,
    /// or nil if more data is needed. A trailing partial line is never
    /// treated as complete, so a command split across TCP segments is not
    /// dispatched truncated.
    static func extractRequestLines(_ buf: Data) -> [String]? {
        // Split on raw LF bytes: Swift treats "\r\n" as one Character, so
        // splitting a String on "\n" would miss CRLF line endings.
        let parts = buf.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        // N newlines produce N+1 parts; we need three complete lines.
        guard parts.count >= 4 else { return nil }
        var lines: [String] = []
        for p in parts.prefix(3) {
            guard let s = String(data: Data(p), encoding: .utf8) else { return nil }
            lines.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines
    }

    // MARK: Authentication

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return hex(bytes)
    }

    static func signature(token: String, timestamp: Int, nonce: String, command: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        let message = Data("\(timestamp)\n\(nonce)\n\(command)".utf8)
        return hex(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func makeRequest(token: String, command: String,
                            now: Date = Date(), nonce: String = makeNonce()) -> String {
        let ts = Int(now.timeIntervalSince1970)
        let sig = signature(token: token, timestamp: ts, nonce: nonce, command: command)
        return "\(version)\nAUTH \(ts) \(nonce) \(sig)\n\(command)\n"
    }

    enum AuthResult: Equatable {
        case ok
        case malformed
        case badSignature
        case stale
        case replay

        /// Wire error code sent back to the client.
        var errorCode: String {
            switch self {
            case .ok: return ""
            case .malformed: return "bad_auth"
            case .badSignature: return "bad_token"
            case .stale: return "stale_request"
            case .replay: return "replay"
            }
        }
    }

    static func verify(authLine: String, command: String, token: String,
                       now: Date = Date(), replayGuard: ReplayGuard) -> AuthResult {
        guard !token.isEmpty else { return .badSignature }
        let fields = authLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 4, fields[0] == "AUTH",
              let ts = Int(fields[1]),
              fields[2].count == 32, fields[2].allSatisfy(\.isHexDigit),
              fields[3].count == 64
        else { return .malformed }
        let nonce = String(fields[2])

        // Check the signature first so unauthenticated junk can't fill the
        // replay cache or probe clock skew.
        let expected = signature(token: token, timestamp: ts, nonce: nonce, command: command)
        guard constantTimeEquals(expected, String(fields[3]).lowercased()) else { return .badSignature }

        guard abs(now.timeIntervalSince1970 - TimeInterval(ts)) <= maxClockSkew else { return .stale }
        guard replayGuard.accept(nonce: nonce, now: now) else { return .replay }
        return .ok
    }

    /// Compares two strings in time that depends only on their length.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: Errors

    /// Human-readable text for an "ERR <code>" response.
    static func describe(errorCode code: String) -> String {
        switch code {
        case "bad_token": return "token mismatch"
        case "stale_request": return "the two Macs' clocks differ by more than \(Int(maxClockSkew))s"
        case "replay": return "request rejected as a replay"
        case "busy": return "the other Mac is switching right now; try again"
        case "bad_protocol": return "the other Mac runs an older BTSwitch; update both Macs"
        case "upgrade_required": return "the other Mac runs a newer BTSwitch; update this Mac"
        case "forbidden_peer": return "the other Mac only accepts requests from local network addresses"
        default: return "destination rejected: \(code)"
        }
    }

    /// If `response` is "ERR <code>", returns the code.
    static func errorCode(in response: String) -> String? {
        guard response.hasPrefix("ERR ") else { return nil }
        return String(response.dropFirst(4)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Port

    static let validPorts = 1...65535

    /// Converts a user-entered port to a UInt16 without trapping.
    static func port(from value: Int) -> UInt16? {
        validPorts.contains(value) ? UInt16(exactly: value) : nil
    }

    // MARK: Hex

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Peripheral reports (CONNECT / VERIFY payload)

struct PeripheralReport: Codable, Equatable {
    var mac: String
    /// CONNECT only: "connected", "already_connected" or "failed".
    var status: String?
    /// VERIFY only.
    var connected: Bool?
    var attempts: Int?
    var error: String?

    var isConnected: Bool {
        if let c = connected { return c }
        return status == "connected" || status == "already_connected"
    }

    static func encodeOK(_ reports: [PeripheralReport]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = (try? enc.encode(reports)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "OK \(json)"
    }

    /// Parses "OK <json>"; nil for errors or malformed responses.
    static func decodeOK(_ response: String) -> [PeripheralReport]? {
        guard response.hasPrefix("OK ") else { return nil }
        let json = Data(response.dropFirst(3).utf8)
        return try? JSONDecoder().decode([PeripheralReport].self, from: json)
    }
}

// MARK: - Replay protection

/// Remembers recently seen nonces for the clock-skew window. Thread-safe.
final class ReplayGuard {
    private var seen: [String: Date] = [:]
    private let lock = NSLock()
    private let window: TimeInterval

    init(window: TimeInterval = BTProtocol.maxClockSkew * 2) {
        self.window = window
    }

    /// Returns false if the nonce has already been used inside the window.
    func accept(nonce: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
        if seen[nonce] != nil { return false }
        seen[nonce] = now
        return true
    }
}

// MARK: - Switch lock

/// Ensures only one switch touches this Mac's peripherals at a time, whether
/// it was started locally (menu click) or remotely (incoming CONNECT).
final class SwitchLock {
    private let lock = NSLock()
    private var held = false

    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if held { return false }
        held = true
        return true
    }

    func release() {
        lock.lock(); held = false; lock.unlock()
    }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held
    }
}

// MARK: - MAC addresses

enum MAC {
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: ":")
    }

    static func isValid(_ s: String) -> Bool {
        let pattern = "^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$"
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Parses a comma-separated list into normalised, valid MACs.
    static func parseList(_ csv: String) -> [String] {
        csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isValid($0) }
            .map { normalize($0) }
    }

    /// Entries in a comma-separated list that aren't valid MACs.
    static func invalidEntries(_ csv: String) -> [String] {
        csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isValid($0) }
    }
}

// MARK: - Peer address filter

/// Decides whether a remote address is on a local/private network. The
/// listener rejects anything else, so joining a network where the port is
/// reachable from outside doesn't expose it.
enum PeerFilter {
    static func isLocal(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (10, _): return true                         // 10.0.0.0/8
        case (172, 16...31): return true                  // 172.16.0.0/12
        case (192, 168): return true                      // 192.168.0.0/16
        case (169, 254): return true                      // link-local
        case (127, _): return true                        // loopback
        case (100, 64...127): return true                 // CGNAT 100.64.0.0/10 (e.g. Tailscale)
        default: return false
        }
    }

    static func isLocal(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }             // fe80::/10 link-local
        if (b[0] & 0xfe) == 0xfc { return true }                             // fc00::/7 unique local
        // IPv4-mapped ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isLocal(ipv4: Array(b[12..<16]))
        }
        return false
    }
}
