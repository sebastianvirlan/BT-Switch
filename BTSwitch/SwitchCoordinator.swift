import Foundation
import Combine

/// Coordinates a single switch:
///   PING → remove on source → CONNECT on destination → VERIFY,
/// and if any peripheral didn't arrive on the destination, reconnects it here
/// so the user isn't left without a keyboard.
///
/// Public API is callable from the main thread; work runs on a background
/// queue and state mutations are marshalled back to main for SwiftUI.
final class SwitchCoordinator: ObservableObject {
    enum Status: Equatable {
        case idle
        case running(String)   // human-readable phase
        case success(Date)
        case failure(String, Date)
    }

    @Published private(set) var status: Status = .idle

    private let settings: AppSettings
    private let pairing: PairingStore
    private let directory: PeerDirectory
    private let bluetooth: BluetoothController
    private let logger: AppLogger
    private let switchLock: SwitchLock
    private let workQueue = DispatchQueue(label: "\(AppInfo.bundleID).coordinator", qos: .userInitiated)

    init(settings: AppSettings, pairing: PairingStore, directory: PeerDirectory,
         bluetooth: BluetoothController, logger: AppLogger, switchLock: SwitchLock) {
        self.settings = settings
        self.pairing = pairing
        self.directory = directory
        self.bluetooth = bluetooth
        self.logger = logger
        self.switchLock = switchLock
    }

    /// Resolves how to reach the paired Mac. Call on main.
    func target() -> Result<PeerTarget, NetworkFailure> {
        guard let peer = pairing.current else { return .failure(.other("not paired with another Mac")) }
        guard let endpoint = directory.endpoint(for: peer, port: settings.port) else {
            return .failure(.notFound(name: peer.name))
        }
        return .success(PeerTarget(endpoint: endpoint, label: peer.name, key: peer.key))
    }

    /// Pings the paired Mac; `completion` gets a user-facing line on main.
    func testConnection(completion: @escaping (_ ok: Bool, _ message: String) -> Void) {
        let t: PeerTarget
        switch target() {
        case .failure(let e): return completion(false, "\(e)")
        case .success(let x): t = x
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = NetworkClient.send(to: t, command: "PING", timeout: 5)
            let (ok, msg): (Bool, String)
            switch r {
            case .success(let s):
                if let pong = PingReply(s) {
                    (ok, msg) = (true, "\(pong.name ?? t.label) is reachable and paired")
                } else if BTProtocol.errorCode(in: s) == "busy" {
                    (ok, msg) = (true, "\(t.label) is reachable and paired (it's busy right now)")
                } else {
                    (ok, msg) = (false, BTProtocol.describe(response: s))
                }
            case .failure(let e):
                (ok, msg) = (false, "\(e)")
            }
            DispatchQueue.main.async { completion(ok, msg) }
        }
    }

    /// Forgets the paired Mac here, and tells it to forget this one too
    /// (best effort: if it's unreachable it'll answer "not paired" later).
    func unpair() {
        guard let peer = pairing.current else { return }
        let t = try? target().get()
        pairing.clear()
        logger.info("unpaired from \(peer.name)")
        guard let t = t else { return }
        workQueue.async { [logger] in
            if case .failure(let e) = NetworkClient.send(to: t, command: "UNPAIR", timeout: 3) {
                logger.warn("couldn't tell \(peer.name) about the unpairing: \(e)")
            }
        }
    }

    /// True while a switch started from this Mac is in flight.
    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// Kick off a switch. Non-blocking — observe `status` for progress.
    func switchToDestination() {
        let macs = settings.peripherals
        guard pairing.current != nil else { return fail("not paired with another Mac; pair in Settings") }
        guard !macs.isEmpty else { return fail("no peripherals configured") }
        let t: PeerTarget
        switch target() {
        case .failure(let e): return fail("\(e)")
        case .success(let x): t = x
        }
        let dest = t.label

        // Also blocks while the other Mac is pushing peripherals to us.
        guard switchLock.tryAcquire() else {
            logger.warn("switch already in progress, ignoring")
            return
        }

        setStatus(.running("pinging \(dest)…"))
        logger.info("switch start: dest=\(dest) macs=\(macs)")

        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.switchLock.release() }
            self.runSwitch(target: t, macs: macs)
        }
    }

    private func runSwitch(target: PeerTarget, macs: [String]) {
        let dest = target.label
        func send(_ command: String, timeout: TimeInterval) -> Result<String, NetworkFailure> {
            NetworkClient.send(to: target, command: command, timeout: timeout)
        }
        let macList = macs.joined(separator: ",")

        // 1. Ping the destination BEFORE removing anything locally, so an
        //    unreachable/misconfigured/busy destination can't strand the
        //    peripherals.
        switch send("PING", timeout: 5) {
        case .failure(let e):
            logger.error("ping failed: \(e)")
            return fail("\(e)")
        case .success(let resp):
            guard let pong = PingReply(resp) else {
                logger.error("ping rejected: \(resp)")
                return fail(BTProtocol.describe(response: resp))
            }
            logger.info("ping ok: \(pong.name ?? dest)")
        }

        // 2. Remove peripherals locally.
        setStatus(.running("removing locally…"))
        for mac in macs {
            let r = bluetooth.remove(mac)
            if r.isFailure {
                logger.warn("  remove \(mac): \(r)")
            } else {
                logger.info("  remove \(mac): \(r)")
            }
        }

        // 3. Ask the destination to pair+connect. Up to 3 attempts per
        //    device with several seconds each, so allow plenty of time.
        setStatus(.running("connecting on \(dest)…"))
        var connectReports: [PeripheralReport]?
        var connectProblem: String?
        switch send("CONNECT \(macList)", timeout: 90) {
        case .failure(let e):
            logger.error("CONNECT failed: \(e)")
            connectProblem = "connect on destination failed: \(e)"
        case .success(let resp):
            logger.info("CONNECT response: \(resp)")
            if let reports = PeripheralReport.decodeOK(resp) {
                connectReports = reports
            } else {
                connectProblem = BTProtocol.describe(response: resp)
            }
        }

        // 4. Verify which peripherals actually ended up on the destination.
        //    If CONNECT timed out the destination may still be busy, so
        //    allow VERIFY time to queue behind it.
        setStatus(.running("verifying…"))
        var onDestination: Set<String>?
        switch send("VERIFY \(macList)", timeout: connectProblem == nil ? 10 : 30) {
        case .success(let resp):
            logger.info("VERIFY: \(resp)")
            if let reports = PeripheralReport.decodeOK(resp) {
                onDestination = Set(reports.filter(\.isConnected).map(\.mac))
            }
        case .failure(let e):
            logger.warn("verify call failed: \(e)")
        }
        // Fall back to what CONNECT reported. If we know nothing, assume
        // nothing arrived — reconnecting here is the safe default.
        let arrived = onDestination
            ?? Set((connectReports ?? []).filter(\.isConnected).map(\.mac))
        let missing = macs.filter { !arrived.contains($0) }

        if missing.isEmpty {
            logger.info("switch complete")
            setStatus(.success(Date()))
            return
        }

        // 5. Roll back: bring the stragglers back to this Mac.
        logger.warn("not on destination: \(missing); reconnecting locally")
        setStatus(.running("reconnecting here…"))
        var stranded: [String] = []
        for mac in missing {
            switch bluetooth.connect(mac) {
            case .success:
                logger.info("  \(mac): reconnected locally")
            case .failure(let e):
                logger.error("  \(mac): local reconnect failed - \(e)")
                stranded.append(mac)
            }
        }

        let reason = connectProblem ?? "\(missing.count) of \(macs.count) peripheral(s) did not connect on \(dest)"
        if stranded.isEmpty {
            fail("\(reason); reconnected here")
        } else {
            fail("\(reason); could not reconnect \(stranded.joined(separator: ", ")) here — wake it and pair via System Settings")
        }
    }

    private func fail(_ msg: String) {
        setStatus(.failure(msg, Date()))
    }

    private func setStatus(_ new: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = new
        }
    }
}
