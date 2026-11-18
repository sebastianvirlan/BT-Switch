import Foundation

// Dependency-free test runner for the pure logic in BTSwitch/Protocol.swift.
// Run with ./test.sh (compiles this file together with Protocol.swift).

var failures = 0
var checks = 0

func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond() {
        failures += 1
        print("FAIL (line \(line)): \(msg)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

let key = Data((0..<32).map { UInt8($0) })
let otherKey = Data(repeating: 0xff, count: 32)
let senderID = "a1b2c3d4e5f6"
let nonce = "00112233445566778899aabbccddeeff"
let now = Date(timeIntervalSince1970: 1_800_000_000)

func authLine(_ request: String) -> (String, String) {
    let lines = BTProtocol.extractRequestLines(Data(request.utf8))!
    return (lines[1], lines[2])
}

func keyFor(_ k: Data) -> (String) -> Data? { { $0 == senderID ? k : nil } }

func signed(_ command: String, at t: Date = now) -> (String, String) {
    authLine(BTProtocol.makeRequest(senderID: senderID, key: key, command: command, now: t, nonce: nonce))
}

// MARK: Framing

test("framing waits for third newline") {
    check(BTProtocol.extractRequestLines(Data("BT-SWITCH/3\nAUTH x\nCONN".utf8)) == nil,
          "partial third line must not dispatch")
    check(BTProtocol.extractRequestLines(Data("BT-SWITCH/3\nAUTH x".utf8)) == nil, "two lines")
    check(BTProtocol.extractRequestLines(Data()) == nil, "empty")
}

test("framing returns complete lines, trims CRLF") {
    let l = BTProtocol.extractRequestLines(Data("BT-SWITCH/3\r\nAUTH x\r\nCONNECT aa\r\n".utf8))
    check(l == ["BT-SWITCH/3", "AUTH x", "CONNECT aa"], "got \(String(describing: l))")
}

test("framing returns leftover bytes after the lines") {
    let r = BTProtocol.extractLines(Data("a\nb\nc\nREVEAL x\n".utf8), count: 3)
    check(r?.0 == ["a", "b", "c"], "lines")
    check(r.map { String(data: $0.1, encoding: .utf8) } == "REVEAL x\n", "leftover")
    check(BTProtocol.extractLines(Data("one\n".utf8), count: 1)?.1.isEmpty == true, "no leftover")
}

// MARK: Auth

test("signed request round-trips") {
    let req = BTProtocol.makeRequest(senderID: senderID, key: key, command: "PING", now: now, nonce: nonce)
    check(req.hasPrefix("BT-SWITCH/4\n"), "version line")
    let (auth, cmd) = authLine(req)
    check(cmd.hasPrefix("SEALED ") && !req.contains("PING"), "command is encrypted on the wire")
    check(Sealing.openRequest(cmd, pairingKey: key, senderID: senderID, nonce: nonce) == "PING", "decrypts")
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(key), now: now,
                            replayGuard: ReplayGuard()) == .ok(senderID: senderID, nonce: nonce), "valid request")
}

test("unknown sender is not paired") {
    let (auth, cmd) = signed("PING")
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: { _ in nil }, now: now,
                            replayGuard: ReplayGuard()) == .notPaired, "no key for sender")
}

test("wrong key is rejected") {
    let (auth, cmd) = signed("PING")
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(otherKey), now: now,
                            replayGuard: ReplayGuard()) == .badSignature, "wrong key")
}

test("tampered command or sender is rejected") {
    let (auth, _) = signed("VERIFY aa:bb:cc:dd:ee:ff")
    check(BTProtocol.verify(authLine: auth, command: "CONNECT aa:bb:cc:dd:ee:ff", keyFor: keyFor(key), now: now,
                            replayGuard: ReplayGuard()) == .badSignature, "command swapped")
    let swapped = auth.replacingOccurrences(of: senderID, with: "ffffffffffff")
    check(BTProtocol.verify(authLine: swapped, command: "VERIFY aa:bb:cc:dd:ee:ff", keyFor: { _ in key }, now: now,
                            replayGuard: ReplayGuard()) == .badSignature, "sender ID is covered by the MAC")
}

test("stale and future requests are rejected") {
    let (auth, cmd) = signed("PING")
    let g = ReplayGuard()
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(key),
                            now: now.addingTimeInterval(61), replayGuard: g) == .stale, "61s late")
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(key),
                            now: now.addingTimeInterval(-61), replayGuard: g) == .stale, "61s early")
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(key),
                            now: now.addingTimeInterval(59), replayGuard: g) == .ok(senderID: senderID, nonce: nonce), "59s late is fine")
}

test("replayed request is rejected") {
    let (auth, cmd) = signed("PING")
    let g = ReplayGuard()
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(key), now: now, replayGuard: g) == .ok(senderID: senderID, nonce: nonce), "first")
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(key), now: now, replayGuard: g) == .replay, "second")
}

test("bad signature does not consume the nonce") {
    let (auth, cmd) = signed("PING")
    let g = ReplayGuard()
    _ = BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(otherKey), now: now, replayGuard: g)
    check(BTProtocol.verify(authLine: auth, command: cmd, keyFor: keyFor(key), now: now, replayGuard: g) == .ok(senderID: senderID, nonce: nonce),
          "nonce still usable after a forged attempt")
}

test("malformed auth lines") {
    let g = ReplayGuard()
    let sig = String(repeating: "0", count: 64)
    for line in ["", "AUTH", "TOKEN abc", "AUTH 1 2 3", "AUTH \(senderID) 1 2 3",
                 "AUTH \(senderID) abc \(nonce) \(sig)",
                 "AUTH \(senderID) 1 zz112233445566778899aabbccddeeff \(sig)",
                 "AUTH 1 \(nonce) \(sig)"] {
        check(BTProtocol.verify(authLine: line, command: "PING", keyFor: keyFor(key), now: now, replayGuard: g) == .malformed,
              "should be malformed: \(line)")
    }
}

test("replay guard forgets nonces after its window") {
    let g = ReplayGuard(window: 10)
    check(g.accept(nonce: "n", now: now), "first")
    check(!g.accept(nonce: "n", now: now.addingTimeInterval(5)), "inside window")
    check(g.accept(nonce: "n", now: now.addingTimeInterval(11)), "after window")
}

test("constant-time compare") {
    check(BTProtocol.constantTimeEquals("abc", "abc"), "equal")
    check(!BTProtocol.constantTimeEquals("abc", "abd"), "differ")
    check(!BTProtocol.constantTimeEquals("abc", "abcd"), "length")
    check(BTProtocol.constantTimeEquals("", ""), "empty")
}

test("error descriptions") {
    check(BTProtocol.errorCode(in: "ERR busy") == "busy", "parse code")
    check(BTProtocol.errorCode(in: "OK pong") == nil, "not an error")
    check(BTProtocol.describe(errorCode: "not_paired").contains("pair them again"), "not_paired text")
    check(BTProtocol.describe(errorCode: "bad_signature").contains("unpair"), "bad_signature text")
    check(BTProtocol.describe(errorCode: "denied").contains("declined"), "denied text")
    check(BTProtocol.describe(errorCode: "weird").contains("weird"), "unknown code passes through")
    check(BTProtocol.describe(response: "huh").contains("unexpected response"), "garbage")
}

// MARK: Encryption

test("requests and replies are encrypted and bound to their context") {
    let sealed = Sealing.sealRequest("CONNECT aa:bb:cc:dd:ee:ff", pairingKey: key, senderID: senderID, nonce: nonce)
    check(!sealed.contains("aa:bb"), "no plaintext")
    check(Sealing.openRequest(sealed, pairingKey: otherKey, senderID: senderID, nonce: nonce) == nil, "wrong key")
    check(Sealing.openRequest(sealed, pairingKey: key, senderID: "someoneelse", nonce: nonce) == nil, "wrong sender")
    check(Sealing.openRequest(sealed, pairingKey: key, senderID: senderID, nonce: String(repeating: "1", count: 32)) == nil,
          "wrong nonce")

    let reply = Sealing.sealReply("OK pong abc Studio", pairingKey: key, requestNonce: nonce)
    check(Sealing.openReply(reply, pairingKey: key, requestNonce: nonce) == .success("OK pong abc Studio"), "reply opens")
    check(Sealing.openReply(reply, pairingKey: key, requestNonce: "other") == .failure(.undecryptable),
          "reply from another request is refused")
}

test("tampered ciphertext is refused") {
    var line = Sealing.sealRequest("PING", pairingKey: key, senderID: senderID, nonce: nonce)
    let b64 = String(line.dropFirst(Sealing.prefix.count))
    var bytes = Data(base64Encoded: b64)!
    bytes[bytes.count / 2] ^= 0x01
    line = Sealing.prefix + bytes.base64EncodedString()
    check(Sealing.openRequest(line, pairingKey: key, senderID: senderID, nonce: nonce) == nil, "bit flip detected")
    check(Sealing.open("SEALED !!!", pairingKey: key, context: Data()) == nil, "garbage")
}

test("plain replies: errors pass, OK is refused") {
    check(Sealing.openReply("ERR not_paired", pairingKey: key, requestNonce: nonce) == .success("ERR not_paired"), "plain error")
    check(Sealing.openReply("OK pong", pairingKey: key, requestNonce: nonce) == .failure(.unencrypted), "downgrade refused")
}

test("same nonce, different messages give different ciphertexts") {
    let a = Sealing.sealRequest("PING", pairingKey: key, senderID: senderID, nonce: nonce)
    let b = Sealing.sealRequest("PING", pairingKey: key, senderID: senderID, nonce: nonce)
    check(a != b, "random AEAD nonce per message")
}

// MARK: Clipboard

test("clipboard command round-trips unicode and newlines") {
    let text = "héllo 👋\nline two\ttab"
    let cmd = Clipboard.command(for: text)
    check(cmd?.hasPrefix("CLIPBOARD ") == true && !(cmd ?? "").contains("\n"), "single line")
    check(cmd.flatMap(Clipboard.text(fromCommand:)) == text, "round-trip")
}

test("clipboard size limits") {
    check(Clipboard.command(for: "") == nil, "empty")
    check(Clipboard.command(for: String(repeating: "a", count: BTProtocol.maxClipboardBytes)) != nil, "at limit")
    check(Clipboard.command(for: String(repeating: "a", count: BTProtocol.maxClipboardBytes + 1)) == nil, "over limit")
    check(Clipboard.text(fromCommand: "CLIPBOARD !!!") == nil, "bad base64")
    check(Clipboard.text(fromCommand: "PING") == nil, "not a clipboard command")
}

test("a full-size clipboard request fits the request limit") {
    let cmd = Clipboard.command(for: String(repeating: "é", count: BTProtocol.maxClipboardBytes / 2))!
    let req = BTProtocol.makeRequest(senderID: senderID, key: key, command: cmd, now: now, nonce: nonce)
    check(req.utf8.count < BTProtocol.maxRequestBytes, "\(req.utf8.count) bytes")
}

// MARK: Port

test("port validation never traps") {
    check(BTProtocol.port(from: 52525) == 52525, "default")
    check(BTProtocol.port(from: 1) == 1, "min")
    check(BTProtocol.port(from: 65535) == 65535, "max")
    for bad in [0, -1, 65536, 70000, Int.max, Int.min] {
        check(BTProtocol.port(from: bad) == nil, "should reject \(bad)")
    }
}

// MARK: MAC

test("MAC parsing") {
    check(MAC.isValid("10:94:BB:B9:73:74"), "colon upper")
    check(MAC.isValid("10-94-bb-b9-73-74"), "dash lower")
    check(!MAC.isValid("10:94:BB:B9:73"), "short")
    check(!MAC.isValid("10:94:BB:B9:73:7G"), "non-hex")
    check(MAC.normalize(" 10-94-BB-B9-73-74 ") == "10:94:bb:b9:73:74", "normalize")
    check(MAC.parseList("10:94:BB:B9:73:74, junk ,0C-E4-41-21-A6-9B,") ==
          ["10:94:bb:b9:73:74", "0c:e4:41:21:a6:9b"], "parseList drops invalid")
    check(MAC.invalidEntries("10:94:BB:B9:73:74, junk ,") == ["junk"], "invalidEntries")
}

// MARK: Reports

test("peripheral reports round-trip") {
    let reports = [
        PeripheralReport(mac: "aa:bb:cc:dd:ee:ff", status: "connected", attempts: 2),
        PeripheralReport(mac: "11:22:33:44:55:66", status: "failed", error: "asleep \"quoted\""),
    ]
    let line = PeripheralReport.encodeOK(reports)
    check(line.hasPrefix("OK ["), "prefix")
    let decoded = PeripheralReport.decodeOK(line)
    check(decoded == reports, "round-trip, got \(String(describing: decoded))")
    check(decoded?.map(\.isConnected) == [true, false], "isConnected")
    check(PeripheralReport.decodeOK("ERR busy") == nil, "error is not a report")
    check(PeripheralReport.decodeOK("OK pong") == nil, "pong is not a report")
}

test("VERIFY reports use connected flag") {
    let d = PeripheralReport.decodeOK(#"OK [{"mac":"aa:bb:cc:dd:ee:ff","connected":false},{"mac":"11:22:33:44:55:66","connected":true}]"#)
    check(d?.map(\.isConnected) == [false, true], "got \(String(describing: d))")
}

// MARK: Peer filter

test("IPv4 peer filter") {
    for ok: [UInt8] in [[192, 168, 1, 2], [10, 0, 0, 1], [172, 16, 0, 1], [172, 31, 255, 255],
                        [169, 254, 1, 1], [127, 0, 0, 1], [100, 64, 0, 1], [100, 127, 1, 1]] {
        check(PeerFilter.isLocal(ipv4: ok), "should allow \(ok)")
    }
    for bad: [UInt8] in [[8, 8, 8, 8], [172, 32, 0, 1], [172, 15, 0, 1], [100, 128, 0, 1], [192, 169, 0, 1], [1, 2, 3]] {
        check(!PeerFilter.isLocal(ipv4: bad), "should reject \(bad)")
    }
}

test("IPv6 peer filter") {
    var loopback = [UInt8](repeating: 0, count: 16); loopback[15] = 1
    var linkLocal = [UInt8](repeating: 0, count: 16); linkLocal[0] = 0xfe; linkLocal[1] = 0x80
    var ula = [UInt8](repeating: 0, count: 16); ula[0] = 0xfd
    var mappedPrivate = [UInt8](repeating: 0, count: 16); mappedPrivate[10] = 0xff; mappedPrivate[11] = 0xff
    mappedPrivate[12] = 192; mappedPrivate[13] = 168; mappedPrivate[14] = 1; mappedPrivate[15] = 5
    var mappedPublic = mappedPrivate; mappedPublic[12] = 8; mappedPublic[13] = 8
    var global = [UInt8](repeating: 0, count: 16); global[0] = 0x20; global[1] = 0x01

    check(PeerFilter.isLocal(ipv6: loopback), "::1")
    check(PeerFilter.isLocal(ipv6: linkLocal), "fe80::")
    check(PeerFilter.isLocal(ipv6: ula), "fd00::")
    check(PeerFilter.isLocal(ipv6: mappedPrivate), "::ffff:192.168.1.5")
    check(!PeerFilter.isLocal(ipv6: mappedPublic), "::ffff:8.8.1.5")
    check(!PeerFilter.isLocal(ipv6: global), "2001::")
}

test("on-link peers are accepted, including public IPv6 on the same /64") {
    func v6(_ prefix: [UInt8], _ tail: UInt8) -> [UInt8] { prefix + [UInt8](repeating: 0, count: 15 - prefix.count) + [tail] }
    let home: [UInt8] = [0x2a, 0x00, 0x23, 0xc7, 0x88, 0x80, 0x44, 0x01]
    let mask64 = [UInt8](repeating: 0xff, count: 8) + [UInt8](repeating: 0, count: 8)
    let nets = [PeerFilter.Network(address: v6(home, 1), netmask: mask64),
                PeerFilter.Network(address: [192, 168, 1, 10], netmask: [255, 255, 255, 0])]

    check(PeerFilter.isOnLink(v6(home, 0xab), networks: nets), "same /64 public IPv6")
    check(!PeerFilter.isOnLink(v6([0x2a, 0x00, 0x23, 0xc7, 0x88, 0x80, 0x44, 0x02], 1), networks: nets), "different /64")
    check(PeerFilter.isOnLink([192, 168, 1, 77], networks: nets), "same IPv4 subnet")
    check(!PeerFilter.isOnLink([8, 8, 8, 8], networks: nets), "internet IPv4")
    check(!PeerFilter.isOnLink([1, 2, 3, 4], networks: [PeerFilter.Network(address: [1, 1, 1, 1], netmask: [0, 0, 0, 0])]),
          "a /0 route doesn't make everything local")
    check(!PeerFilter.isOnLink([192, 168, 1, 77], networks: []), "no interfaces")
}

// MARK: Switch lock

test("switch lock is exclusive") {
    let l = SwitchLock()
    check(l.tryAcquire(), "first acquire")
    check(l.isHeld, "held")
    check(!l.tryAcquire(), "second acquire fails")
    l.release()
    check(!l.isHeld, "released")
    check(l.tryAcquire(), "reacquire")
}

// MARK: Pairing

/// Runs both sides of the pairing exchange in-process.
func simulatePairing(initiator i: Pairing.Ephemeral, responder r: Pairing.Ephemeral) -> (Pairing.Result?, Pairing.Result?) {
    let ri = Pairing.derive(myKey: i, peerPublicKey: r.publicKey, initiatorID: "init", responderID: "resp",
                            initiatorPub: i.publicKey, initiatorNonce: i.nonce,
                            responderPub: r.publicKey, responderNonce: r.nonce)
    let rr = Pairing.derive(myKey: r, peerPublicKey: i.publicKey, initiatorID: "init", responderID: "resp",
                            initiatorPub: i.publicKey, initiatorNonce: i.nonce,
                            responderPub: r.publicKey, responderNonce: r.nonce)
    return (ri, rr)
}

test("both sides derive the same key and code") {
    let (a, b) = simulatePairing(initiator: .init(), responder: .init())
    check(a != nil && a == b, "key and code agree")
    check(a?.key.count == 32, "32-byte key")
    check(a.map { $0.code.count == 6 && $0.code.allSatisfy(\.isNumber) } == true, "6-digit code, got \(a?.code ?? "nil")")
    let confirmI = Pairing.confirmation(key: a!.key, initiatorID: "init", responderID: "resp")
    let confirmR = Pairing.confirmation(key: b!.key, initiatorID: "init", responderID: "resp")
    check(confirmI == confirmR, "confirmation matches")
}

test("a man in the middle produces different codes") {
    // M runs separate exchanges with each side.
    let i = Pairing.Ephemeral(), r = Pairing.Ephemeral(), m1 = Pairing.Ephemeral(), m2 = Pairing.Ephemeral()
    let (iSide, _) = simulatePairing(initiator: i, responder: m1)
    let (_, rSide) = simulatePairing(initiator: m2, responder: r)
    check(iSide!.code != rSide!.code, "codes differ (1 in a million chance of a false failure)")
    check(iSide!.key != rSide!.key, "keys differ")
}

test("commitment binds the initiator's key") {
    let i = Pairing.Ephemeral(), other = Pairing.Ephemeral()
    let c = Pairing.commitment(publicKey: i.publicKey, nonce: i.nonce)
    check(c.count == 64, "sha256 hex")
    check(c == Pairing.commitment(publicKey: i.publicKey, nonce: i.nonce), "deterministic")
    check(c != Pairing.commitment(publicKey: other.publicKey, nonce: i.nonce), "different key")
    check(c != Pairing.commitment(publicKey: i.publicKey, nonce: other.nonce), "different nonce")
}

test("invalid peer key is refused") {
    let i = Pairing.Ephemeral()
    check(Pairing.derive(myKey: i, peerPublicKey: Data([1, 2, 3]), initiatorID: "a", responderID: "b",
                         initiatorPub: i.publicKey, initiatorNonce: i.nonce,
                         responderPub: Data([1, 2, 3]), responderNonce: i.nonce) == nil, "short key")
}

test("pairing messages round-trip") {
    let e = Pairing.Ephemeral()
    let hello = Pairing.PairHello(id: "abc123", name: "Sebastian’s MacBook Pro", commitment: String(repeating: "a", count: 64))
    let parts = hello.lines.components(separatedBy: "\n")
    check(Pairing.PairHello(line2: parts[0], line3: parts[1]) == hello, "hello, got \(hello.lines)")

    let key = Pairing.KeyMessage(id: "def456", name: "Studio Mac mini", publicKey: e.publicKey, nonce: e.nonce)
    check(Pairing.KeyMessage(key.line) == key, "key message")

    let reveal = Pairing.Reveal(publicKey: e.publicKey, nonce: e.nonce)
    check(Pairing.Reveal(reveal.line) == reveal, "reveal")
}

test("pairing messages reject junk") {
    check(Pairing.PairHello(line2: "PAIR abc", line3: "COMMIT x") == nil, "missing name")
    check(Pairing.PairHello(line2: "PAIR a/b \(BTProtocol.encodeName("x"))", line3: "COMMIT \(String(repeating: "a", count: 64))") == nil, "bad id")
    check(Pairing.PairHello(line2: "PAIR abc \(BTProtocol.encodeName("x"))", line3: "COMMIT abc") == nil, "short commit")
    check(Pairing.KeyMessage("KEY abc eA== 00 00") == nil, "short key")
    check(Pairing.Reveal("REVEAL zz 00") == nil, "bad hex")
    check(Pairing.Reveal("ERR denied") == nil, "error")
}

test("names survive encoding, newlines flattened") {
    check(BTProtocol.decodeName(BTProtocol.encodeName("Studio Mac\nmini")) == "Studio Mac mini", "flattened")
    check(BTProtocol.decodeName(BTProtocol.encodeName("   ")) == nil, "blank")
    check(BTProtocol.decodeName("!!!") == nil, "not base64")
    check(BTProtocol.data(hex: "00ff10") == Data([0, 255, 16]), "hex decode")
    check(BTProtocol.data(hex: "0") == nil && BTProtocol.data(hex: "zz") == nil, "bad hex")
}

test("code formatting") {
    check(Pairing.formatCode("482913") == "482 913", "grouped")
    check(Pairing.formatCode("12") == "12", "passthrough")
}

test("paired peer survives JSON round-trip") {
    let p = PairedPeer(id: "abc", name: "Mac", key: key, address: "192.168.1.2", pairedAt: now)
    let d = try! JSONEncoder().encode(p)
    check((try? JSONDecoder().decode(PairedPeer.self, from: d)) == p, "round-trip")
}

test("error reply parsing") {
    check(ErrorReply("ERR bad_signature abc123") == ErrorReply("ERR bad_signature abc123"), "equatable")
    check(ErrorReply("ERR bad_signature abc123")?.code == "bad_signature", "code")
    check(ErrorReply("ERR bad_signature abc123")?.detail == "abc123", "detail")
    check(ErrorReply("ERR busy")?.detail == nil, "no detail")
    check(ErrorReply("OK pong") == nil, "not an error")
    check(ErrorReply("ERR ") == nil, "empty code")
}

// MARK: Ping identity

test("ping reply round-trips identity") {
    let r = PingReply(instanceID: "abc123def456", name: "Studio Mac\nmini")
    check(r.encoded == "OK pong abc123def456 Studio Mac mini", "newline flattened, got \(r.encoded)")
    let parsed = PingReply(r.encoded)
    check(parsed?.instanceID == "abc123def456", "id")
    check(parsed?.name == "Studio Mac mini", "name with spaces")
}

test("ping reply accepts bare pong, rejects others") {
    let bare = PingReply("OK pong")
    check(bare != nil && bare?.instanceID == nil && bare?.name == nil, "bare pong from earlier build")
    check(PingReply("OK pong abc123")?.name == nil, "id only")
    check(PingReply("OK pongish") == nil, "prefix must be a whole word")
    check(PingReply("ERR busy") == nil, "error")
}

// MARK: Network failures

test("socket errors map to user-facing causes") {
    check(NetworkFailure.from(posix: .ECONNREFUSED, host: "h") == .refused(host: "h"), "refused")
    check(NetworkFailure.from(posix: .EHOSTUNREACH, host: "h") == .unreachable(host: "h"), "host unreach")
    check(NetworkFailure.from(posix: .ENETUNREACH, host: "h") == .unreachable(host: "h"), "net unreach")
    check(NetworkFailure.from(posix: .ETIMEDOUT, host: "h") == .connectTimeout(host: "h"), "timeout")
    check(NetworkFailure.from(posix: .EPERM, host: "h") == .localNetworkDenied, "privacy denial")
    check(NetworkFailure.from(posix: .EINVAL, host: "h") == nil, "no better explanation")
    check("\(NetworkFailure.refused(host: "mac.local"))".contains("isn't running"), "refused text")
    check("\(NetworkFailure.localNetworkDenied)".contains("Local Network"), "denied text")
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
