import Foundation
import Network

/// TCP listener implementing the BT-SWITCH/3 protocol (see Protocol.swift),
/// advertised on the local network via Bonjour.
final class NetworkServer: ObservableObject {
    enum ListenerState: Equatable {
        case starting
        case listening(port: Int)
        case failed(String)
    }

    /// Published on the main queue so the menu bar and Settings can show
    /// when this Mac isn't actually reachable.
    @Published private(set) var state: ListenerState = .starting

    struct PairingRequest {
        let name: String
        let address: String
        let code: String
        /// Name of the Mac this would replace, if already paired elsewhere.
        let replacing: String?
    }

    /// Asks the user to approve a pairing request. Called on any queue;
    /// must eventually call `decide` (from any queue) unless dismissed.
    /// Returns a closure that dismisses the prompt, used when the requester
    /// gives up or the request times out.
    var requestApproval: ((_ request: PairingRequest, _ decide: @escaping (Bool) -> Void) -> () -> Void)?

    private let settings: AppSettings
    private let bluetooth: BluetoothController
    private let logger: AppLogger
    private let switchLock: SwitchLock
    private let pairing: PairingStore
    private let replayGuard = ReplayGuard()
    private var listener: NWListener?
    /// Connection handling, including all pairing state, runs on this queue.
    private let acceptQueue = DispatchQueue(label: "\(AppInfo.bundleID).server.accept")
    private let workQueue = DispatchQueue(label: "\(AppInfo.bundleID).server.work", qos: .userInitiated)
    private var pairingInProgress = false   // acceptQueue only

    static let approvalTimeout: TimeInterval = 60

    init(settings: AppSettings, bluetooth: BluetoothController, logger: AppLogger,
         switchLock: SwitchLock, pairing: PairingStore) {
        self.settings = settings
        self.bluetooth = bluetooth
        self.logger = logger
        self.switchLock = switchLock
        self.pairing = pairing
    }

    func start() {
        let portNumber = Int(BTProtocol.port(from: settings.port) ?? UInt16(BTProtocol.defaultPort))
        let port = NWEndpoint.Port(rawValue: UInt16(portNumber))!
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        let l: NWListener
        do {
            l = try NWListener(using: params, on: port)
        } catch {
            fail(Self.describe(listenerError: error, port: portNumber))
            return
        }

        // Advertise so the other Mac can find this one by name.
        let name = AppInfo.computerName
        let txt = NWTXTRecord(["id": AppInfo.instanceID, "name": name])
        l.service = NWListener.Service(name: name, type: BTProtocol.bonjourType, domain: nil, txtRecord: txt)

        l.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.logger.info("listening on port \(portNumber)")
                self.setState(.listening(port: portNumber))
            case .failed(let e):
                self.fail(Self.describe(listenerError: e, port: portNumber))
                l.cancel()
            case .waiting(let e):
                self.fail(Self.describe(listenerError: e, port: portNumber))
            case .cancelled:
                self.logger.info("listener stopped")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        l.start(queue: acceptQueue)
        self.listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func fail(_ message: String) {
        logger.error("not listening: \(message)")
        setState(.failed(message))
    }

    private func setState(_ new: ListenerState) {
        DispatchQueue.main.async { [weak self] in self?.state = new }
    }

    private static func describe(listenerError error: Error, port: Int) -> String {
        if case NWError.posix(.EADDRINUSE) = error {
            return "port \(port) is already in use; is another copy of BTSwitch running?"
        }
        if case NWError.posix(.EACCES) = error {
            return "not allowed to listen on port \(port)"
        }
        return "listener on port \(port) failed: \(error.localizedDescription)"
    }

    // MARK: - Connection handling

    private func handle(connection conn: NWConnection) {
        conn.start(queue: acceptQueue)
        guard Self.isLocalPeer(conn.endpoint) else {
            logger.warn("rejected connection from non-local address \(Self.peer(conn))")
            respond(conn: conn, "ERR forbidden_peer\n")
            return
        }
        receiveRequest(conn: conn)
    }

    private static func peer(_ conn: NWConnection) -> String {
        if case .hostPort(let host, _) = conn.endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return "\(host)"
            }
        }
        return "\(conn.endpoint)"
    }

    private static func isLocalPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let bytes: [UInt8]
        switch host {
        case .ipv4(let a):
            bytes = [UInt8](a.rawValue)
            if PeerFilter.isLocal(ipv4: bytes) { return true }
        case .ipv6(let a):
            bytes = [UInt8](a.rawValue)
            if PeerFilter.isLocal(ipv6: bytes) { return true }
        default:
            return false
        }
        return PeerFilter.isOnLink(bytes, networks: localNetworks())
    }

    /// This Mac's interface addresses and netmasks (IPv4 and IPv6).
    private static func localNetworks() -> [PeerFilter.Network] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        // The netmask's sa_family is sometimes left as 0, so read it using
        // the family of the address it belongs to.
        func bytes(_ sa: UnsafeMutablePointer<sockaddr>?, family: Int32) -> [UInt8]? {
            guard let sa = sa else { return nil }
            switch family {
            case AF_INET:
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                }
            case AF_INET6:
                return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
            default:
                return nil
            }
        }

        var out: [PeerFilter.Network] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let family = ifa.pointee.ifa_addr.map({ Int32($0.pointee.sa_family) }),
                  let addr = bytes(ifa.pointee.ifa_addr, family: family),
                  let mask = bytes(ifa.pointee.ifa_netmask, family: family), mask.count == addr.count
            else { continue }
            out.append(PeerFilter.Network(address: addr, netmask: mask))
        }
        return out
    }

    /// Read until three complete lines have arrived (max 4 KB), then dispatch.
    private func receiveRequest(conn: NWConnection, accumulated: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.warn("receive error from \(Self.peer(conn)): \(error.localizedDescription)")
                conn.cancel()
                return
            }

            var buf = accumulated
            if let d = data { buf.append(d) }

            if let (lines, rest) = BTProtocol.extractLines(buf, count: 3) {
                self.dispatch(conn: conn, version: lines[0], line2: lines[1], line3: lines[2], leftover: rest)
                return
            }
            if isComplete {
                self.logger.warn("rejected \(Self.peer(conn)): incomplete request")
                self.respond(conn: conn, "ERR incomplete_request\n")
                return
            }
            if buf.count > BTProtocol.maxRequestBytes {
                self.logger.warn("rejected \(Self.peer(conn)): request too long")
                self.respond(conn: conn, "ERR too_long\n")
                return
            }
            self.receiveRequest(conn: conn, accumulated: buf)
        }
    }

    private func dispatch(conn: NWConnection, version: String, line2: String, line3: String, leftover: Data) {
        let from = Self.peer(conn)
        if version != BTProtocol.version {
            if BTProtocol.legacyVersions.contains(version) {
                logger.warn("rejected \(from): it runs an older BTSwitch (\(version)); update that Mac")
                respond(conn: conn, "ERR upgrade_required\n")
            } else {
                logger.warn("rejected \(from): unrecognised protocol line")
                respond(conn: conn, "ERR bad_protocol\n")
            }
            return
        }

        if line2.hasPrefix("PAIR ") {
            guard let hello = Pairing.PairHello(line2: line2, line3: line3) else {
                logger.warn("rejected \(from): malformed pairing request")
                respond(conn: conn, "ERR bad_pairing\n")
                return
            }
            handlePairing(conn: conn, hello: hello, from: from, leftover: leftover)
            return
        }

        let auth = BTProtocol.verify(authLine: line2, command: line3,
                                     keyFor: { [pairing] in pairing.key(for: $0) },
                                     replayGuard: replayGuard)
        let sender: String
        let requestNonce: String
        switch auth {
        case .ok(let id, let nonce):
            sender = id
            requestNonce = nonce
        case .notPaired:
            logger.warn("rejected \(from): not paired with this Mac")
            respond(conn: conn, "ERR not_paired\n")
            return
        case .stale:
            logger.warn("rejected \(from): timestamp off by more than \(Int(BTProtocol.maxClockSkew))s; check both clocks")
            respond(conn: conn, "ERR \(auth.errorCode)\n")
            return
        default:
            logger.warn("rejected \(from): \(auth.errorCode)")
            respond(conn: conn, "ERR \(auth.errorCode)\n")
            return
        }

        guard let key = pairing.key(for: sender),
              let command = Sealing.openRequest(line3, pairingKey: key, senderID: sender, nonce: requestNonce)
        else {
            logger.warn("rejected \(from): couldn't decrypt the request")
            respond(conn: conn, "ERR bad_seal\n")
            return
        }

        // Remember where the paired Mac is, in case Bonjour can't see it later.
        pairing.updateAddress(from, for: sender)
        let peerName = pairing.current?.name ?? from

        // Every reply from here on is encrypted and bound to this request.
        let reply: (String) -> Void = { [weak self] text in
            self?.respond(conn: conn, Sealing.sealReply(text, pairingKey: key, requestNonce: requestNonce) + "\n")
        }
        dispatchCommand(command, from: peerName, reply: reply)
    }

    private func dispatchCommand(_ command: String, from peerName: String, reply: @escaping (String) -> Void) {
        let line3 = command
        switch line3 {
        case "PING":
            if switchLock.isHeld {
                logger.info("ping from \(peerName) while busy")
                reply("ERR busy")
            } else {
                logger.info("ping from \(peerName)")
                reply(PingReply(instanceID: AppInfo.instanceID, name: AppInfo.computerName).encoded)
            }

        case "UNPAIR":
            logger.info("\(peerName) unpaired from this Mac")
            reply("OK unpaired")
            pairing.clear()

        case let s where s.hasPrefix(Clipboard.commandPrefix):
            guard let text = Clipboard.text(fromCommand: s) else {
                logger.warn("clipboard from \(peerName) rejected: malformed or too large")
                reply("ERR too_long")
                return
            }
            DispatchQueue.main.async { [settings, logger] in
                guard settings.acceptClipboard else {
                    logger.info("ignored clipboard text from \(peerName) (accepting is turned off)")
                    reply("ERR clipboard_disabled")
                    return
                }
                ClipboardBridge.write(text, from: peerName)
                logger.info("received clipboard text from \(peerName) (\(text.utf8.count) bytes)")
                reply("OK clipboard")
            }

        case let s where s.hasPrefix("VERIFY "):
            let macs = MAC.parseList(String(s.dropFirst("VERIFY ".count)))
            logger.info("verify from \(peerName): \(macs)")
            workQueue.async { [weak self] in
                guard let self = self else { return }
                let reports = macs.map { PeripheralReport(mac: $0, connected: self.bluetooth.isReady($0)) }
                reply(PeripheralReport.encodeOK(reports))
            }

        case let s where s.hasPrefix("CONNECT "):
            let macs = MAC.parseList(String(s.dropFirst("CONNECT ".count)))
            guard switchLock.tryAcquire() else {
                logger.warn("connect from \(peerName) rejected: a switch is already running on this Mac")
                reply("ERR busy")
                return
            }
            logger.info("connect from \(peerName): \(macs)")
            DispatchQueue.main.async { [settings, logger] in
                if settings.adoptPeripheralsIfNoneSelected(macs) {
                    logger.info("using the same \(macs.count) peripheral(s) as \(peerName) for switching back")
                }
            }
            workQueue.async { [weak self] in
                guard let self = self else { return }
                defer { self.switchLock.release() }
                reply(self.handleConnect(macs: macs))
            }

        case let s where s.hasPrefix("RELEASE "):
            // The other Mac is rolling back a switch that only partly worked.
            let macs = MAC.parseList(String(s.dropFirst("RELEASE ".count)))
            guard switchLock.tryAcquire() else {
                logger.warn("release from \(peerName) rejected: a switch is already running on this Mac")
                reply("ERR busy")
                return
            }
            logger.info("release requested by \(peerName): \(macs)")
            workQueue.async { [weak self] in
                guard let self = self else { return }
                defer { self.switchLock.release() }
                let reports = macs.map { mac -> PeripheralReport in
                    let r = self.bluetooth.remove(mac)
                    self.logger.info("  release \(mac): \(r)")
                    return PeripheralReport(mac: mac, status: r.isFailure ? "failed" : "released",
                                            error: r.isFailure ? "\(r)" : nil)
                }
                reply(PeripheralReport.encodeOK(reports))
            }

        default:
            logger.warn("rejected \(peerName): unknown command")
            reply("ERR bad_command")
        }
    }

    // MARK: - Pairing (responder side; runs on acceptQueue)

    private func handlePairing(conn: NWConnection, hello: Pairing.PairHello, from: String, leftover: Data) {
        guard !pairingInProgress, !switchLock.isHeld, let requestApproval = requestApproval else {
            logger.warn("pairing request from \(hello.name) (\(from)) rejected: busy")
            respond(conn: conn, "ERR busy\n")
            return
        }
        guard hello.id != AppInfo.instanceID else {
            respond(conn: conn, "ERR bad_pairing\n")
            return
        }
        pairingInProgress = true
        logger.info("pairing request from \(hello.name) (\(from))")

        let mine = Pairing.Ephemeral()
        let channel = LineChannel(connection: conn, label: hello.name, queue: acceptQueue, buffer: leftover)
        channel.send(Pairing.KeyMessage(id: AppInfo.instanceID, name: AppInfo.computerName,
                                        publicKey: mine.publicKey, nonce: mine.nonce).line)

        channel.readLine(timeout: 15) { [weak self] r in
            guard let self = self else { return }
            guard case .success(let line) = r, let reveal = Pairing.Reveal(line) else {
                return self.abandonPairing(conn: conn, name: hello.name, reason: "no valid key from the other Mac")
            }
            // The initiator committed to this key before seeing ours; if it
            // doesn't match, someone tried to steer the code.
            guard Pairing.commitment(publicKey: reveal.publicKey, nonce: reveal.nonce) == hello.commitment else {
                return self.abandonPairing(conn: conn, name: hello.name, reason: "key didn't match its commitment")
            }
            guard let result = Pairing.derive(
                myKey: mine, peerPublicKey: reveal.publicKey,
                initiatorID: hello.id, responderID: AppInfo.instanceID,
                initiatorPub: reveal.publicKey, initiatorNonce: reveal.nonce,
                responderPub: mine.publicKey, responderNonce: mine.nonce)
            else { return self.abandonPairing(conn: conn, name: hello.name, reason: "invalid key") }

            self.askUser(conn: conn, channel: channel, hello: hello, from: from,
                         result: result, requestApproval: requestApproval)
        }
    }

    private func abandonPairing(conn: NWConnection, name: String, reason: String) {
        logger.warn("pairing with \(name) failed: \(reason)")
        pairingInProgress = false
        respond(conn: conn, "ERR bad_pairing\n")
    }

    private func askUser(conn: NWConnection, channel: LineChannel, hello: Pairing.PairHello, from: String,
                         result: Pairing.Result,
                         requestApproval: (PairingRequest, @escaping (Bool) -> Void) -> () -> Void) {
        let existing = pairing.current
        let request = PairingRequest(
            name: hello.name, address: from, code: result.code,
            replacing: existing.flatMap { $0.id == hello.id ? nil : $0.name })

        // All of the following runs on acceptQueue, so no locking needed.
        var decided = false
        var dismiss: () -> Void = {}

        let conclude: (_ outcome: String) -> Void = { [weak self] outcome in
            guard let self = self, !decided else { return }
            decided = true
            dismiss()
            self.pairingInProgress = false
            switch outcome {
            case "allowed":
                self.pairing.save(PairedPeer(id: hello.id, name: hello.name, key: result.key,
                                             address: from, pairedAt: Date()))
                self.logger.info("paired with \(hello.name)")
                let confirm = Pairing.confirmation(key: result.key, initiatorID: hello.id,
                                                   responderID: AppInfo.instanceID)
                self.respond(conn: conn, "OK \(confirm)\n")
            case "cancelled":
                self.logger.info("pairing request from \(hello.name) was cancelled")
                conn.cancel()
            case "timed out":
                self.logger.info("pairing request from \(hello.name) timed out")
                self.respond(conn: conn, "ERR timeout\n")
            default:
                self.logger.info("pairing request from \(hello.name) denied")
                self.respond(conn: conn, "ERR denied\n")
            }
        }

        dismiss = requestApproval(request) { [acceptQueue] allowed in
            acceptQueue.async { conclude(allowed ? "allowed" : "denied") }
        }
        acceptQueue.asyncAfter(deadline: .now() + Self.approvalTimeout) { conclude("timed out") }
        // If the requester cancels, take the prompt down.
        channel.watchForClose { [acceptQueue] in acceptQueue.async { conclude("cancelled") } }
    }

    // MARK: - Commands

    /// Connects the peripherals here and returns the reply line.
    private func handleConnect(macs: [String]) -> String {
        var reports: [PeripheralReport] = []
        for mac in macs {
            if bluetooth.isReady(mac) {
                logger.info("  \(mac): already connected")
                reports.append(PeripheralReport(mac: mac, status: "already_connected"))
                continue
            }
            var lastErr: BluetoothController.ConnectError?
            var connectedOnAttempt: Int?
            for attempt in 1...3 {
                switch bluetooth.connect(mac) {
                case .success:
                    logger.info("  \(mac): connected (attempt \(attempt))")
                    connectedOnAttempt = attempt
                case .failure(let e):
                    lastErr = e
                    logger.warn("  \(mac): attempt \(attempt) failed - \(e)")
                    if attempt < 3 { Thread.sleep(forTimeInterval: 2) }
                }
                if connectedOnAttempt != nil { break }
            }
            if let attempt = connectedOnAttempt {
                reports.append(PeripheralReport(mac: mac, status: "connected", attempts: attempt))
            } else {
                reports.append(PeripheralReport(mac: mac, status: "failed",
                                                error: lastErr.map { "\($0)" } ?? "unknown"))
            }
        }
        return PeripheralReport.encodeOK(settle(reports))
    }

    /// Some peripherals (notably the Magic Mouse) occasionally report
    /// connected and drop a moment later. Re-check after a short pause and
    /// retry any that fell off before answering.
    private func settle(_ reports: [PeripheralReport]) -> [PeripheralReport] {
        guard reports.contains(where: \.isConnected) else { return reports }
        Thread.sleep(forTimeInterval: 1.5)
        return reports.map { report in
            guard report.isConnected, !bluetooth.isReady(report.mac) else { return report }
            logger.warn("  \(report.mac): dropped or didn't finish pairing; retrying")
            for attempt in 1...2 {
                if case .success = bluetooth.connect(report.mac) {
                    Thread.sleep(forTimeInterval: 1)
                    if bluetooth.isReady(report.mac) {
                        logger.info("  \(report.mac): reconnected and stayed (retry \(attempt))")
                        return PeripheralReport(mac: report.mac, status: "connected",
                                                attempts: (report.attempts ?? 1) + attempt)
                    }
                }
            }
            logger.warn("  \(report.mac): kept dropping")
            return PeripheralReport(mac: report.mac, status: "failed", error: "kept dropping or didn't finish pairing")
        }
    }

    private func respond(conn: NWConnection, _ s: String) {
        conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in
            // Half-close so the client knows we're done.
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
        })
    }
}
