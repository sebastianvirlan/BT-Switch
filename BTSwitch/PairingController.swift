import Foundation
import Network
import Combine

/// Runs the initiator side of pairing (see the protocol notes in
/// Protocol.swift) and publishes progress for the Settings window.
final class PairingController: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting(String)
        case awaitingApproval(name: String, code: String)
        case paired(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .connecting, .awaitingApproval: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private let store: PairingStore
    private let logger: AppLogger
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).pairing")
    /// Bumped on every attempt/cancel so late callbacks from an abandoned
    /// attempt are ignored.
    private var attempt = 0
    private var connection: NWConnection?

    init(store: PairingStore, logger: AppLogger) {
        self.store = store
        self.logger = logger
    }

    /// Pair with a Mac found on the network.
    func pair(with discovered: PeerDirectory.Discovered) {
        start(endpoint: discovered.endpoint, label: discovered.name, typedAddress: nil)
    }

    /// Pair with a Mac by IP address or hostname.
    func pair(address: String, port: Int) {
        let host = address.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let raw = BTProtocol.port(from: port), let p = NWEndpoint.Port(rawValue: raw) else {
            state = .failed("enter the other Mac's IP address or hostname")
            return
        }
        start(endpoint: .hostPort(host: NWEndpoint.Host(host), port: p), label: host, typedAddress: host)
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.attempt += 1
            self.connection?.cancel()
            self.connection = nil
        }
        state = .idle
    }

    func reset() {
        if !state.isBusy { state = .idle }
    }

    // MARK: - Exchange

    private func start(endpoint: NWEndpoint, label: String, typedAddress: String?) {
        state = .connecting(label)
        logger.info("pairing with \(label)…")
        queue.async { [weak self] in self?.run(endpoint: endpoint, label: label, typedAddress: typedAddress) }
    }

    private func run(endpoint: NWEndpoint, label: String, typedAddress: String?) {
        attempt += 1
        let myAttempt = attempt
        connection?.cancel()

        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        let channel = LineChannel(connection: conn, label: label, queue: queue)
        let mine = Pairing.Ephemeral()
        var started = false

        func fail(_ message: String) {
            guard myAttempt == attempt else { return }
            attempt += 1
            conn.cancel()
            connection = nil
            logger.warn("pairing with \(label) failed: \(message)")
            publish(.failed(message))
        }

        conn.stateUpdateHandler = { [weak self] st in
            guard let self = self, myAttempt == self.attempt else { return }
            switch st {
            case .ready where !started:
                started = true
                // Remember the address we actually reached as a fallback for
                // when Bonjour can't see the other Mac later.
                let learned = typedAddress ?? Self.remoteHost(of: conn)
                self.exchange(channel: channel, mine: mine, label: label, address: learned,
                              attempt: myAttempt, fail: fail)
            case .failed(let e), .waiting(let e):
                fail("\(NetworkFailure.from(e, connection: conn, label: label))")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func exchange(channel: LineChannel, mine: Pairing.Ephemeral, label: String, address: String?,
                          attempt myAttempt: Int, fail: @escaping (String) -> Void) {
        let hello = Pairing.PairHello(id: AppInfo.instanceID, name: AppInfo.computerName,
                                      commitment: Pairing.commitment(publicKey: mine.publicKey, nonce: mine.nonce))
        channel.send("\(BTProtocol.version)\n\(hello.lines)")

        channel.readLine(timeout: 15) { [weak self] r in
            guard let self = self, myAttempt == self.attempt else { return }
            let line: String
            switch r {
            case .failure(let e): return fail("\(e)")
            case .success(let l): line = l
            }
            if ErrorReply(line) != nil { return fail(BTProtocol.describe(response: line)) }
            guard let theirs = Pairing.KeyMessage(line) else {
                return fail("\(label) sent an unexpected reply; make sure both Macs run the same BTSwitch build")
            }
            guard theirs.id != AppInfo.instanceID else { return fail("that address is this Mac; pick the other Mac") }

            guard let result = Pairing.derive(
                myKey: mine, peerPublicKey: theirs.publicKey,
                initiatorID: AppInfo.instanceID, responderID: theirs.id,
                initiatorPub: mine.publicKey, initiatorNonce: mine.nonce,
                responderPub: theirs.publicKey, responderNonce: theirs.nonce)
            else { return fail("\(theirs.name) sent an invalid key") }

            channel.send(Pairing.Reveal(publicKey: mine.publicKey, nonce: mine.nonce).line)
            self.logger.info("waiting for \(theirs.name) to approve (code \(Pairing.formatCode(result.code)))")
            self.publish(.awaitingApproval(name: theirs.name, code: result.code))

            // The other Mac gives its user 60s to answer.
            channel.readLine(timeout: 75) { [weak self] r in
                guard let self = self, myAttempt == self.attempt else { return }
                let reply: String
                switch r {
                case .failure(let e): return fail("\(e)")
                case .success(let l): reply = l
                }
                if ErrorReply(reply) != nil { return fail(BTProtocol.describe(response: reply)) }

                let expected = Pairing.confirmation(key: result.key, initiatorID: AppInfo.instanceID,
                                                    responderID: theirs.id)
                guard reply.hasPrefix("OK "),
                      BTProtocol.constantTimeEquals(String(reply.dropFirst(3)).lowercased(), expected)
                else { return fail("\(theirs.name) approved, but the keys didn't match; try again") }

                self.store.save(PairedPeer(id: theirs.id, name: theirs.name, key: result.key,
                                           address: address, pairedAt: Date()))
                self.logger.info("paired with \(theirs.name)")
                self.attempt += 1
                channel.connection.cancel()
                self.connection = nil
                self.publish(.paired(theirs.name))
            }
        }
    }

    private func publish(_ s: State) {
        DispatchQueue.main.async { [weak self] in self?.state = s }
    }

    static func remoteHost(of conn: NWConnection) -> String? {
        guard case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }
}
