import Foundation
import CryptoKit

// Pure, dependency-free logic shared by the client, server and settings.
// Nothing in this file touches AppKit, IOBluetooth or the network, so it is
// compiled into the test runner as-is (see test.sh).

// MARK: - Wire protocol

/// BT-SWITCH/4 wire protocol (line-delimited UTF-8, one exchange per TCP connection).
///
/// Commands between paired Macs:
///
///     line 1: BT-SWITCH/4
///     line 2: AUTH <sender_id> <unix_timestamp> <nonce_hex> <hmac_hex>
///     line 3: SEALED <base64 ChaChaPoly box of the command>
///     reply:  SEALED <base64 ChaChaPoly box of the reply>   (or a plain "ERR <code>")
///
/// The command and reply are encrypted with a key derived from the pairing
/// key (see `Sealing`); the request box is bound to the sender and nonce,
/// the reply box to the request nonce. `hmac_hex` = hex(HMAC-SHA256(key:
/// pairing key, message: "<sender_id>\n<timestamp>\n<nonce>\n<line 3>")).
/// The pairing key never crosses the network. Requests outside
/// `maxClockSkew` are rejected and each nonce is accepted once, so captured
/// requests can't be replayed. Plain-text "OK" replies are refused.
///
///     PING                       -> "OK pong <instance_id> <name>" (or "ERR busy" mid-switch)
///     CONNECT <mac1>,<mac2>,...  -> "OK <json [PeripheralReport]>"
///     VERIFY  <mac1>,<mac2>,...  -> "OK <json [PeripheralReport]>"
///     RELEASE <mac1>,<mac2>,...  -> "OK <json [PeripheralReport]>" (unpair them here; used to roll back)
///     CLIPBOARD <base64 text>    -> "OK clipboard" (or "ERR clipboard_disabled")
///     UNPAIR                     -> "OK unpaired"
///
/// Pairing (initiator I → responder R), see `Pairing`:
///
///     I: BT-SWITCH/4
///     I: PAIR <id_I> <name_I_base64>
///     I: COMMIT <sha256(pub_I || nonce_I)>
///     R: KEY <id_R> <name_R_base64> <pub_R> <nonce_R>
///     I: REVEAL <pub_I> <nonce_I>
///        (both show the same 6-digit code; R's user clicks Allow or Deny)
///     R: OK <confirm_hmac>   |   ERR denied | ERR timeout | ERR busy
///
/// I commits to its key before seeing R's, so neither side — nor anyone in
/// the middle — can steer the 6-digit code; a man-in-the-middle shows up as
/// different codes on the two screens.
///
/// Errors are "ERR <code> [detail]"; see `BTProtocol.describe(errorCode:)`.
enum BTProtocol {
    static let version = "BT-SWITCH/4"
    static let legacyVersions: Set<String> = ["BT-SWITCH/1", "BT-SWITCH/2", "BT-SWITCH/3"]
    static let maxClockSkew: TimeInterval = 60
    /// Large enough for a sealed clipboard payload.
    static let maxRequestBytes = 512 * 1024
    /// Largest clipboard text sent, in UTF-8 bytes.
    static let maxClipboardBytes = 256 * 1024
    static let defaultPort = 52525
    static let bonjourType = "_btswitch._tcp"

    // MARK: Framing

    /// Returns the three request lines once all three are newline-terminated,
    /// or nil if more data is needed. A trailing partial line is never
    /// treated as complete, so a command split across TCP segments is not
    /// dispatched truncated.
    static func extractRequestLines(_ buf: Data) -> [String]? {
        guard let (lines, _) = extractLines(buf, count: 3) else { return nil }
        return lines
    }

    /// Splits off `count` complete LF-terminated lines; returns them (trimmed)
    /// and whatever bytes follow. Splits on raw bytes because Swift treats
    /// "\r\n" as one Character, so splitting a String on "\n" misses CRLF.
    static func extractLines(_ buf: Data, count: Int) -> ([String], Data)? {
        var lines: [String] = []
        var rest = buf[...]
        for _ in 0..<count {
            guard let nl = rest.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            guard let s = String(data: Data(rest[rest.startIndex..<nl]), encoding: .utf8) else { return nil }
            lines.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[(nl + 1)...]
        }
        return (lines, Data(rest))
    }

    // MARK: Authentication

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            bytes = (0..<n).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    static func makeNonce() -> String { hex(randomBytes(16)) }

    static func signature(key: Data, senderID: String, timestamp: Int, nonce: String, command: String) -> String {
        let message = Data("\(senderID)\n\(timestamp)\n\(nonce)\n\(command)".utf8)
        return hex(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// Builds an encrypted, signed request. Keep `nonce` to open the reply.
    static func makeRequest(senderID: String, key: Data, command: String,
                            now: Date = Date(), nonce: String = makeNonce()) -> String {
        let ts = Int(now.timeIntervalSince1970)
        let sealed = Sealing.sealRequest(command, pairingKey: key, senderID: senderID, nonce: nonce)
        let sig = signature(key: key, senderID: senderID, timestamp: ts, nonce: nonce, command: sealed)
        return "\(version)\nAUTH \(senderID) \(ts) \(nonce) \(sig)\n\(sealed)\n"
    }

    enum AuthResult: Equatable {
        case ok(senderID: String, nonce: String)
        case malformed
        case notPaired
        case badSignature
        case stale
        case replay

        /// Wire error code sent back to the client.
        var errorCode: String {
            switch self {
            case .ok: return ""
            case .malformed: return "bad_auth"
            case .notPaired: return "not_paired"
            case .badSignature: return "bad_signature"
            case .stale: return "stale_request"
            case .replay: return "replay"
            }
        }
    }

    /// `keyFor` returns the pairing key for a sender ID, or nil if that Mac
    /// isn't paired with this one.
    static func verify(authLine: String, command: String, keyFor: (String) -> Data?,
                       now: Date = Date(), replayGuard: ReplayGuard) -> AuthResult {
        let fields = authLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 5, fields[0] == "AUTH",
              !fields[1].isEmpty, fields[1].count <= 64,
              let ts = Int(fields[2]),
              fields[3].count == 32, fields[3].allSatisfy(\.isHexDigit),
              fields[4].count == 64
        else { return .malformed }
        let sender = String(fields[1])
        let nonce = String(fields[3])

        guard let key = keyFor(sender) else { return .notPaired }

        // Check the signature first so unauthenticated junk can't fill the
        // replay cache or probe clock skew.
        let expected = signature(key: key, senderID: sender, timestamp: ts, nonce: nonce, command: command)
        guard constantTimeEquals(expected, String(fields[4]).lowercased()) else { return .badSignature }

        guard abs(now.timeIntervalSince1970 - TimeInterval(ts)) <= maxClockSkew else { return .stale }
        guard replayGuard.accept(nonce: "\(sender):\(nonce)", now: now) else { return .replay }
        return .ok(senderID: sender, nonce: nonce)
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

    /// Human-readable text for an "ERR <code> [detail]" response.
    static func describe(errorCode code: String, detail: String? = nil) -> String {
        switch code {
        case "not_paired": return "the other Mac isn't paired with this one; pair them again in Settings"
        case "bad_signature": return "the pairing keys don't match; unpair and pair the two Macs again"
        case "bad_auth": return "malformed request; make sure both Macs run the same BTSwitch build"
        case "stale_request": return "the two Macs' clocks differ by more than \(Int(maxClockSkew))s; turn on automatic date & time on both"
        case "replay": return "request rejected as a replay"
        case "clipboard_disabled": return "the other Mac doesn't accept clipboard text; turn it on in its Settings"
        case "too_long": return "the request was too large for the other Mac"
        case "bad_seal": return "the other Mac couldn't decrypt the request; unpair and pair the two Macs again"
        case "busy": return "the other Mac is busy (switching or showing a pairing request); try again"
        case "denied": return "pairing was declined on the other Mac"
        case "timeout": return "nobody approved the pairing on the other Mac in time"
        case "bad_pairing": return "pairing failed: the other Mac couldn't verify this Mac's key; try again"
        case "bad_protocol": return "the other Mac runs an older BTSwitch; update both Macs"
        case "upgrade_required": return "the other Mac runs a newer BTSwitch; update this Mac"
        case "forbidden_peer": return "the other Mac only accepts requests from local network addresses"
        default: return "the other Mac rejected the request: \(code)"
        }
    }

    /// Describes any non-success response: an "ERR …" reply or something unexpected.
    static func describe(response: String) -> String {
        if let e = ErrorReply(response) {
            return describe(errorCode: e.code, detail: e.detail)
        }
        return "unexpected response: \(response)"
    }

    /// If `response` is "ERR <code> [detail]", returns the code.
    static func errorCode(in response: String) -> String? {
        ErrorReply(response)?.code
    }

    // MARK: Port

    static let validPorts = 1...65535

    /// Converts a user-entered port to a UInt16 without trapping.
    static func port(from value: Int) -> UInt16? {
        validPorts.contains(value) ? UInt16(exactly: value) : nil
    }

    // MARK: Encoding

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// Names travel base64-encoded so spaces and odd characters are safe.
    static func encodeName(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    static func decodeName(_ s: String) -> String? {
        guard let d = Data(base64Encoded: s), let name = String(data: d, encoding: .utf8) else { return nil }
        let clean = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : String(clean.prefix(100))
    }

    static func isValidInstanceID(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

// MARK: - Encryption

/// Encrypts commands and replies between paired Macs with ChaCha20-Poly1305.
/// The encryption key is derived from the pairing key with HKDF, so it's
/// independent of the HMAC key and existing pairings don't need redoing.
enum Sealing {
    static let prefix = "SEALED "

    static func encryptionKey(from pairingKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: pairingKey),
                               info: Data("btswitch-encryption-v1".utf8), outputByteCount: 32)
    }

    static func requestContext(senderID: String, nonce: String) -> Data {
        Data("btswitch-request\n\(senderID)\n\(nonce)".utf8)
    }

    static func replyContext(requestNonce: String) -> Data {
        Data("btswitch-reply\n\(requestNonce)".utf8)
    }

    static func seal(_ plaintext: String, pairingKey: Data, context: Data) -> String {
        // ChaChaPoly.seal only throws for invalid key/nonce sizes, which
        // can't happen here.
        let box = try! ChaChaPoly.seal(Data(plaintext.utf8), using: encryptionKey(from: pairingKey),
                                       authenticating: context)
        return prefix + box.combined.base64EncodedString()
    }

    /// nil if the line isn't sealed, was tampered with, or used another key/context.
    static func open(_ line: String, pairingKey: Data, context: Data) -> String? {
        guard line.hasPrefix(prefix),
              let combined = Data(base64Encoded: String(line.dropFirst(prefix.count))),
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plain = try? ChaChaPoly.open(box, using: encryptionKey(from: pairingKey), authenticating: context)
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func sealRequest(_ command: String, pairingKey: Data, senderID: String, nonce: String) -> String {
        seal(command, pairingKey: pairingKey, context: requestContext(senderID: senderID, nonce: nonce))
    }

    static func openRequest(_ line: String, pairingKey: Data, senderID: String, nonce: String) -> String? {
        open(line, pairingKey: pairingKey, context: requestContext(senderID: senderID, nonce: nonce))
    }

    static func sealReply(_ reply: String, pairingKey: Data, requestNonce: String) -> String {
        seal(reply, pairingKey: pairingKey, context: replyContext(requestNonce: requestNonce))
    }

    enum ReplyError: Error, Equatable { case undecryptable, unencrypted }

    /// Opens a reply. Plain "ERR …" replies pass through (they're sent
    /// before or instead of authentication and carry no secrets); a plain
    /// "OK …" is refused so a downgrade can't slip through.
    static func openReply(_ line: String, pairingKey: Data, requestNonce: String) -> Result<String, ReplyError> {
        if line.hasPrefix(prefix) {
            guard let plain = open(line, pairingKey: pairingKey, context: replyContext(requestNonce: requestNonce))
            else { return .failure(.undecryptable) }
            return .success(plain)
        }
        return ErrorReply(line) != nil ? .success(line) : .failure(.unencrypted)
    }
}

// MARK: - Clipboard

enum Clipboard {
    static let commandPrefix = "CLIPBOARD "

    /// nil if the text is empty or too large to send.
    static func command(for text: String) -> String? {
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty, bytes.count <= BTProtocol.maxClipboardBytes else { return nil }
        return commandPrefix + bytes.base64EncodedString()
    }

    static func text(fromCommand command: String) -> String? {
        guard command.hasPrefix(commandPrefix),
              let data = Data(base64Encoded: String(command.dropFirst(commandPrefix.count))),
              data.count <= BTProtocol.maxClipboardBytes
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Pairing

/// The paired Mac, as stored in the Keychain.
struct PairedPeer: Codable, Equatable {
    var id: String
    var name: String
    /// 32-byte HMAC key shared with that Mac.
    var key: Data
    /// Last known address (typed by the user or learned from a connection);
    /// used when the Mac can't be found via Bonjour.
    var address: String?
    var pairedAt: Date
}

/// Cryptography for the pairing exchange (X25519 + commitment + 6-digit code).
enum Pairing {
    struct Ephemeral {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let nonce: Data
        var publicKey: Data { privateKey.publicKey.rawRepresentation }

        init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = BTProtocol.randomBytes(16)) {
            self.privateKey = privateKey
            self.nonce = nonce
        }
    }

    /// Everything both sides derive once keys and nonces are exchanged.
    struct Result: Equatable {
        let key: Data
        let code: String          // "482913"
    }

    static func commitment(publicKey: Data, nonce: Data) -> String {
        var d = Data("btswitch-commit\n".utf8)
        d.append(publicKey); d.append(nonce)
        return BTProtocol.hex(SHA256.hash(data: d))
    }

    /// Derives the shared key and the 6-digit confirmation code. Inputs are
    /// always ordered initiator-first so both sides compute the same values.
    static func derive(myKey: Ephemeral, peerPublicKey: Data,
                       initiatorID: String, responderID: String,
                       initiatorPub: Data, initiatorNonce: Data,
                       responderPub: Data, responderNonce: Data) -> Result? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
              let shared = try? myKey.privateKey.sharedSecretFromKeyAgreement(with: peer)
        else { return nil }

        var salt = initiatorNonce; salt.append(responderNonce)
        let info = Data("btswitch-pair-v3\n\(initiatorID)\n\(responderID)".utf8)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                      sharedInfo: info, outputByteCount: 32)
        let key = symmetric.withUnsafeBytes { Data($0) }

        var sasInput = Data("btswitch-sas-v3\n".utf8)
        for part in [initiatorPub, responderPub, initiatorNonce, responderNonce] { sasInput.append(part) }
        let digest = Array(SHA256.hash(data: sasInput))
        let n = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        return Result(key: key, code: String(format: "%06u", n))
    }

    /// Sent by the responder after its user approves; proves it derived the same key.
    static func confirmation(key: Data, initiatorID: String, responderID: String) -> String {
        let msg = Data("btswitch-pair-confirm\n\(initiatorID)\n\(responderID)".utf8)
        return BTProtocol.hex(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    /// "482913" -> "482 913"
    static func formatCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    // MARK: Messages

    struct PairHello: Equatable {   // line 2 + 3 from the initiator
        let id: String, name: String, commitment: String
        var lines: String { "PAIR \(id) \(BTProtocol.encodeName(name))\nCOMMIT \(commitment)" }

        init(id: String, name: String, commitment: String) {
            self.id = id; self.name = name; self.commitment = commitment
        }

        init?(line2: String, line3: String) {
            let a = line2.split(separator: " "), b = line3.split(separator: " ")
            guard a.count == 3, a[0] == "PAIR", BTProtocol.isValidInstanceID(a[1]),
                  let n = BTProtocol.decodeName(String(a[2])),
                  b.count == 2, b[0] == "COMMIT", b[1].count == 64, b[1].allSatisfy(\.isHexDigit)
            else { return nil }
            id = String(a[1]); name = n; commitment = String(b[1]).lowercased()
        }
    }

    struct KeyMessage: Equatable {  // responder -> initiator
        let id: String, name: String, publicKey: Data, nonce: Data
        var line: String {
            "KEY \(id) \(BTProtocol.encodeName(name)) \(BTProtocol.hex(publicKey)) \(BTProtocol.hex(nonce))"
        }

        init(id: String, name: String, publicKey: Data, nonce: Data) {
            self.id = id; self.name = name; self.publicKey = publicKey; self.nonce = nonce
        }

        init?(_ line: String) {
            let f = line.split(separator: " ")
            guard f.count == 5, f[0] == "KEY", BTProtocol.isValidInstanceID(f[1]),
                  let n = BTProtocol.decodeName(String(f[2])),
                  let pub = BTProtocol.data(hex: String(f[3])), pub.count == 32,
                  let nonce = BTProtocol.data(hex: String(f[4])), nonce.count == 16
            else { return nil }
            id = String(f[1]); name = n; publicKey = pub; self.nonce = nonce
        }
    }

    struct Reveal: Equatable {      // initiator -> responder
        let publicKey: Data, nonce: Data
        var line: String { "REVEAL \(BTProtocol.hex(publicKey)) \(BTProtocol.hex(nonce))" }

        init(publicKey: Data, nonce: Data) { self.publicKey = publicKey; self.nonce = nonce }

        init?(_ line: String) {
            let f = line.split(separator: " ")
            guard f.count == 3, f[0] == "REVEAL",
                  let pub = BTProtocol.data(hex: String(f[1])), pub.count == 32,
                  let nonce = BTProtocol.data(hex: String(f[2])), nonce.count == 16
            else { return nil }
            publicKey = pub; self.nonce = nonce
        }
    }
}

// MARK: - Replies

/// "ERR <code> [detail]"
struct ErrorReply: Equatable {
    let code: String
    let detail: String?

    init?(_ response: String) {
        guard response.hasPrefix("ERR ") else { return nil }
        let rest = response.dropFirst(4).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return nil }
        code = String(first)
        detail = parts.count > 1 ? String(parts[1]) : nil
    }
}

/// "OK pong [<instance_id> <computer name>]". The identity confirms which
/// machine answered. A bare "OK pong" is accepted too.
struct PingReply: Equatable {
    /// Whether the Mac can take peripherals right now.
    enum Readiness: String {
        case ready
        /// Answering from a dark wake (or about to sleep); not safe yet.
        case waking
        case bluetoothOff = "bluetooth_off"
    }

    let instanceID: String?
    let name: String?
    /// nil from builds that predate the field; treat as ready.
    let readiness: Readiness?

    init(instanceID: String, name: String, readiness: Readiness? = nil) {
        self.instanceID = instanceID
        self.name = name
        self.readiness = readiness
    }

    init?(_ response: String) {
        guard response == "OK pong" || response.hasPrefix("OK pong ") else { return nil }
        var rest = Substring(response.dropFirst("OK pong".count).trimmingCharacters(in: .whitespaces))
        func token() -> Substring? {
            guard !rest.isEmpty else { return nil }
            let t = rest.prefix { $0 != " " }
            return t
        }
        func consume(_ t: Substring) {
            rest = rest.dropFirst(t.count).drop { $0 == " " }
        }
        if let t = token() {
            instanceID = String(t)
            consume(t)
        } else {
            instanceID = nil
        }
        // "state=<readiness>" sits between the id and the name.
        if let t = token(), t.hasPrefix("state=") {
            readiness = Readiness(rawValue: String(t.dropFirst("state=".count)))
            consume(t)
        } else {
            readiness = nil
        }
        name = rest.isEmpty ? nil : String(rest)
    }

    var encoded: String {
        guard let id = instanceID else { return "OK pong" }
        var parts = ["OK pong", id]
        if let r = readiness { parts.append("state=\(r.rawValue)") }
        // Keep it on one line whatever the computer is called.
        let n = (name ?? "").components(separatedBy: .newlines).joined(separator: " ")
        if !n.isEmpty { parts.append(n) }
        return parts.joined(separator: " ")
    }
}

// MARK: - Network failures

/// Why a request to the other Mac failed, phrased for the user.
enum NetworkFailure: Error, Equatable, CustomStringConvertible {
    case invalidAddress(String)
    case notFound(name: String)
    case refused(host: String)
    case unreachable(host: String)
    case localNetworkDenied
    case cannotResolve(host: String)
    case connectTimeout(host: String)
    case noResponse(host: String, seconds: Int)
    case other(String)

    var description: String {
        switch self {
        case .invalidAddress(let s):
            return "invalid address: \(s)"
        case .notFound(let name):
            return "can't find \(name) on the network; check it's awake, on the same network and running BTSwitch"
        case .refused(let host):
            return "\(host) refused the connection; BTSwitch isn't running there or uses a different port"
        case .unreachable(let host):
            return "no route to \(host); check it's awake and on the same network"
        case .localNetworkDenied:
            return "macOS blocked the connection; allow BTSwitch under System Settings → Privacy & Security → Local Network"
        case .cannotResolve(let host):
            return "can't resolve \(host); try the other Mac's IP address instead"
        case .connectTimeout(let host):
            return "timed out connecting to \(host); check it's awake and on the same network"
        case .noResponse(let host, let seconds):
            return "\(host) accepted the connection but didn't answer within \(seconds)s"
        case .other(let s):
            return s
        }
    }

    /// Maps a socket error to a user-facing cause; nil if there's no better
    /// explanation than the system's own message.
    static func from(posix code: POSIXErrorCode, host: String) -> NetworkFailure? {
        switch code {
        case .ECONNREFUSED: return .refused(host: host)
        case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN: return .unreachable(host: host)
        case .ETIMEDOUT: return .connectTimeout(host: host)
        case .EPERM, .EACCES: return .localNetworkDenied
        default: return nil
        }
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

    /// One of this Mac's own networks: an interface address and its netmask.
    struct Network: Equatable {
        let address: [UInt8]
        let netmask: [UInt8]
    }

    /// True if `remote` is on the same network segment as one of this Mac's
    /// interfaces. Covers home networks that hand out public IPv6
    /// addresses, which `isLocal` alone would reject.
    static func isOnLink(_ remote: [UInt8], networks: [Network]) -> Bool {
        networks.contains { n in
            n.address.count == remote.count && n.netmask.count == remote.count
                && n.netmask.contains { $0 != 0 }   // ignore /0
                && zip(zip(remote, n.address), n.netmask).allSatisfy { ($0.0 & $1) == ($0.1 & $1) }
        }
    }
}
