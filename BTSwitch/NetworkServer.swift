import Foundation
import Network

/// TCP listener implementing the BT-SWITCH/2 protocol (see Protocol.swift).
final class NetworkServer: ObservableObject {
    enum ListenerState: Equatable {
        case starting
        case listening(port: Int)
        case failed(String)
    }

    /// Published on the main queue so the menu bar and Settings can show
    /// when this Mac isn't actually reachable.
    @Published private(set) var state: ListenerState = .starting

    private let settings: AppSettings
    private let bluetooth: BluetoothController
    private let logger: AppLogger
    private let switchLock: SwitchLock
    private let replayGuard = ReplayGuard()
    private var listener: NWListener?
    private let acceptQueue = DispatchQueue(label: "\(AppInfo.bundleID).server.accept")
    private let workQueue = DispatchQueue(label: "\(AppInfo.bundleID).server.work", qos: .userInitiated)

    init(settings: AppSettings, bluetooth: BluetoothController, logger: AppLogger, switchLock: SwitchLock) {
        self.settings = settings
        self.bluetooth = bluetooth
        self.logger = logger
        self.switchLock = switchLock
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
        guard Self.isLocalPeer(conn.endpoint) else {
            logger.warn("rejected connection from non-local address \(Self.peer(conn))")
            conn.start(queue: acceptQueue)
            respond(conn: conn, "ERR forbidden_peer\n")
            return
        }
        conn.start(queue: acceptQueue)
        receiveRequest(conn: conn)
    }

    private static func peer(_ conn: NWConnection) -> String {
        if case .hostPort(let host, _) = conn.endpoint { return "\(host)" }
        return "\(conn.endpoint)"
    }

    private static func isLocalPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return PeerFilter.isLocal(ipv4: [UInt8](a.rawValue))
        case .ipv6(let a): return PeerFilter.isLocal(ipv6: [UInt8](a.rawValue))
        default: return false
        }
    }

    /// Read until three complete lines have arrived (max 4 KB), then dispatch.
    private func receiveRequest(conn: NWConnection, accumulated: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: BTProtocol.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.warn("receive error from \(Self.peer(conn)): \(error.localizedDescription)")
                conn.cancel()
                return
            }

            var buf = accumulated
            if let d = data { buf.append(d) }

            if let lines = BTProtocol.extractRequestLines(buf) {
                self.dispatch(conn: conn, version: lines[0], auth: lines[1], command: lines[2])
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

    private func dispatch(conn: NWConnection, version: String, auth: String, command: String) {
        let from = Self.peer(conn)
        if version != BTProtocol.version {
            if BTProtocol.legacyVersions.contains(version) {
                logger.warn("rejected \(from): it uses old protocol \(version); update BTSwitch on that Mac")
                respond(conn: conn, "ERR upgrade_required\n")
            } else {
                logger.warn("rejected \(from): unrecognised protocol line")
                respond(conn: conn, "ERR bad_protocol\n")
            }
            return
        }

        let token = settings.token
        let authResult = BTProtocol.verify(authLine: auth, command: command,
                                           token: token, replayGuard: replayGuard)
        switch authResult {
        case .ok:
            break
        case .badSignature:
            let fp = BTProtocol.fingerprint(token)
            logger.warn("rejected \(from): token mismatch (this Mac's token fingerprint is \(fp))")
            respond(conn: conn, "ERR bad_token \(fp)\n")
            return
        case .stale:
            logger.warn("rejected \(from): timestamp off by more than \(Int(BTProtocol.maxClockSkew))s; check both clocks")
            respond(conn: conn, "ERR \(authResult.errorCode)\n")
            return
        default:
            logger.warn("rejected \(from): \(authResult.errorCode)")
            respond(conn: conn, "ERR \(authResult.errorCode)\n")
            return
        }

        switch command {
        case "PING":
            if switchLock.isHeld {
                logger.info("ping from \(from) while busy")
                respond(conn: conn, "ERR busy\n")
            } else {
                logger.info("ping from \(from)")
                let reply = PingReply(instanceID: AppInfo.instanceID, name: AppInfo.computerName)
                respond(conn: conn, reply.encoded + "\n")
            }

        case let s where s.hasPrefix("VERIFY "):
            let macs = MAC.parseList(String(s.dropFirst("VERIFY ".count)))
            logger.info("verify from \(from): \(macs)")
            workQueue.async { [weak self] in
                guard let self = self else { return }
                let reports = macs.map { PeripheralReport(mac: $0, connected: self.bluetooth.isConnected($0)) }
                self.respond(conn: conn, PeripheralReport.encodeOK(reports) + "\n")
            }

        case let s where s.hasPrefix("CONNECT "):
            let macs = MAC.parseList(String(s.dropFirst("CONNECT ".count)))
            guard switchLock.tryAcquire() else {
                logger.warn("connect from \(from) rejected: a switch is already running on this Mac")
                respond(conn: conn, "ERR busy\n")
                return
            }
            logger.info("connect from \(from): \(macs)")
            workQueue.async { [weak self] in
                guard let self = self else { return }
                defer { self.switchLock.release() }
                self.handleConnect(conn: conn, macs: macs)
            }

        default:
            logger.warn("rejected \(from): unknown command")
            respond(conn: conn, "ERR bad_command\n")
        }
    }

    private func handleConnect(conn: NWConnection, macs: [String]) {
        var reports: [PeripheralReport] = []
        for mac in macs {
            if bluetooth.isConnected(mac) {
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
        respond(conn: conn, PeripheralReport.encodeOK(reports) + "\n")
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
