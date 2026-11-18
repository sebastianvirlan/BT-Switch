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

let token = "0123456789abcdef0123456789abcdef"
let nonce = "00112233445566778899aabbccddeeff"
let now = Date(timeIntervalSince1970: 1_800_000_000)

func authLine(_ request: String) -> (String, String) {
    let lines = BTProtocol.extractRequestLines(Data(request.utf8))!
    return (lines[1], lines[2])
}

// MARK: Framing

test("framing waits for third newline") {
    check(BTProtocol.extractRequestLines(Data("BT-SWITCH/2\nAUTH x\nCONN".utf8)) == nil,
          "partial third line must not dispatch")
    check(BTProtocol.extractRequestLines(Data("BT-SWITCH/2\nAUTH x".utf8)) == nil, "two lines")
    check(BTProtocol.extractRequestLines(Data()) == nil, "empty")
}

test("framing returns complete lines, trims CRLF") {
    let l = BTProtocol.extractRequestLines(Data("BT-SWITCH/2\r\nAUTH x\r\nCONNECT aa\r\n".utf8))
    check(l == ["BT-SWITCH/2", "AUTH x", "CONNECT aa"], "got \(String(describing: l))")
}

test("framing ignores trailing data after third line") {
    let l = BTProtocol.extractRequestLines(Data("a\nb\nc\nextra".utf8))
    check(l == ["a", "b", "c"], "got \(String(describing: l))")
}

// MARK: Auth

test("signed request round-trips") {
    let req = BTProtocol.makeRequest(token: token, command: "PING", now: now, nonce: nonce)
    check(req.hasPrefix("BT-SWITCH/2\n"), "version line")
    check(!req.contains(token), "token must not appear on the wire")
    let (auth, cmd) = authLine(req)
    check(cmd == "PING", "command")
    check(BTProtocol.verify(authLine: auth, command: cmd, token: token, now: now,
                            replayGuard: ReplayGuard()) == .ok, "valid request")
}

test("wrong token is rejected") {
    let (auth, cmd) = authLine(BTProtocol.makeRequest(token: token, command: "PING", now: now, nonce: nonce))
    check(BTProtocol.verify(authLine: auth, command: cmd, token: "other", now: now,
                            replayGuard: ReplayGuard()) == .badSignature, "wrong token")
    check(BTProtocol.verify(authLine: auth, command: cmd, token: "", now: now,
                            replayGuard: ReplayGuard()) == .badSignature, "empty local token")
}

test("tampered command is rejected") {
    let (auth, _) = authLine(BTProtocol.makeRequest(token: token, command: "VERIFY aa:bb:cc:dd:ee:ff", now: now, nonce: nonce))
    check(BTProtocol.verify(authLine: auth, command: "CONNECT aa:bb:cc:dd:ee:ff", token: token, now: now,
                            replayGuard: ReplayGuard()) == .badSignature, "command swapped")
}

test("stale and future requests are rejected") {
    let (auth, cmd) = authLine(BTProtocol.makeRequest(token: token, command: "PING", now: now, nonce: nonce))
    let g = ReplayGuard()
    check(BTProtocol.verify(authLine: auth, command: cmd, token: token,
                            now: now.addingTimeInterval(61), replayGuard: g) == .stale, "61s late")
    check(BTProtocol.verify(authLine: auth, command: cmd, token: token,
                            now: now.addingTimeInterval(-61), replayGuard: g) == .stale, "61s early")
    check(BTProtocol.verify(authLine: auth, command: cmd, token: token,
                            now: now.addingTimeInterval(59), replayGuard: g) == .ok, "59s late is fine")
}

test("replayed request is rejected") {
    let (auth, cmd) = authLine(BTProtocol.makeRequest(token: token, command: "PING", now: now, nonce: nonce))
    let g = ReplayGuard()
    check(BTProtocol.verify(authLine: auth, command: cmd, token: token, now: now, replayGuard: g) == .ok, "first")
    check(BTProtocol.verify(authLine: auth, command: cmd, token: token, now: now, replayGuard: g) == .replay, "second")
}

test("bad signature does not consume the nonce") {
    let (auth, cmd) = authLine(BTProtocol.makeRequest(token: token, command: "PING", now: now, nonce: nonce))
    let g = ReplayGuard()
    _ = BTProtocol.verify(authLine: auth, command: cmd, token: "wrong", now: now, replayGuard: g)
    check(BTProtocol.verify(authLine: auth, command: cmd, token: token, now: now, replayGuard: g) == .ok,
          "nonce still usable after a forged attempt")
}

test("malformed auth lines") {
    let g = ReplayGuard()
    for line in ["", "AUTH", "TOKEN \(token)", "AUTH 1 2 3", "AUTH abc \(nonce) \(String(repeating: "0", count: 64))",
                 "AUTH 1 zz112233445566778899aabbccddeeff \(String(repeating: "0", count: 64))"] {
        check(BTProtocol.verify(authLine: line, command: "PING", token: token, now: now, replayGuard: g) == .malformed,
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
    check(BTProtocol.describe(errorCode: "bad_token") == "token mismatch", "bad_token text")
    check(BTProtocol.describe(errorCode: "weird").contains("weird"), "unknown code passes through")
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

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
