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
    private let power: PowerMonitor
    private let workQueue = DispatchQueue(label: "\(AppInfo.bundleID).coordinator", qos: .userInitiated)

    init(settings: AppSettings, pairing: PairingStore, directory: PeerDirectory,
         bluetooth: BluetoothController, logger: AppLogger, switchLock: SwitchLock, power: PowerMonitor) {
        self.settings = settings
        self.pairing = pairing
        self.directory = directory
        self.bluetooth = bluetooth
        self.logger = logger
        self.switchLock = switchLock
        self.power = power
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
            let r = NetworkClient.send(to: t, command: "PING", timeout: 8)
            let (ok, msg): (Bool, String)
            switch r {
            case .success(let s):
                if let pong = PingReply(s) {
                    let who = pong.name ?? t.label
                    switch pong.readiness {
                    case .bluetoothOff?: (ok, msg) = (false, "\(who) is reachable and paired, but its Bluetooth is off")
                    case .waking?: (ok, msg) = (true, "\(who) is reachable and paired (it's still waking up)")
                    default: (ok, msg) = (true, "\(who) is reachable and paired")
                    }
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

        // Read the clipboard now, on main, so it's what was copied at click time.
        var clipboard: String?
        if settings.sendClipboard {
            switch ClipboardBridge.readForSending() {
            case .text(let s): clipboard = s
            case .skipped(let why): logger.info("clipboard not sent: \(why)")
            }
        }

        // Also blocks while the other Mac is pushing peripherals to us.
        guard switchLock.tryAcquire() else {
            logger.warn("switch already in progress, ignoring")
            return
        }

        let names = settings.peripheralNames
        setStatus(.running("pinging \(dest)…"))
        logger.info("switch start: dest=\(dest) macs=\(macs)")

        let allowSleep = power.preventSleep("BTSwitch: moving peripherals to \(dest)")
        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                allowSleep()
                self.switchLock.release()
            }
            let succeeded = self.runSwitch(target: t, macs: macs, names: names)
            if succeeded, let text = clipboard {
                self.sendClipboard(text, to: t)
            }
        }
    }

    /// Returns true if every peripheral arrived on the destination.
    private func runSwitch(target: PeerTarget, macs: [String], names: [String: String]) -> Bool {
        let dest = target.label
        func label(_ macs: [String]) -> String {
            macs.map { names[$0] ?? $0 }.joined(separator: ", ")
        }
        func send(_ command: String, timeout: TimeInterval) -> Result<String, NetworkFailure> {
            NetworkClient.send(to: target, command: command, timeout: timeout)
        }
        func sendWatched(_ command: String, timeout: TimeInterval) -> Result<String, WatchedFailure> {
            self.sendWatched(command, to: target, timeout: timeout)
        }
        let macList = macs.joined(separator: ",")

        // 1. Ping the destination BEFORE removing anything locally, so an
        //    unreachable/misconfigured/busy destination can't strand the
        //    peripherals. A sleeping Mac can answer from a dark wake and
        //    fall asleep again mid-pairing, so wait until it says it's
        //    fully awake. The ping itself wakes it up.
        let wakeDeadline = Date().addingTimeInterval(Self.wakeWait)
        while true {
            switch send("PING", timeout: 8) {
            case .failure(let e):
                logger.error("ping failed: \(e)")
                fail("\(e)"); return false
            case .success(let resp):
                guard let pong = PingReply(resp) else {
                    logger.error("ping rejected: \(resp)")
                    fail(BTProtocol.describe(response: resp)); return false
                }
                let who = pong.name ?? dest
                switch pong.readiness {
                case .bluetoothOff?:
                    logger.error("\(who) has Bluetooth turned off")
                    fail("Bluetooth is off on \(who); nothing was moved"); return false
                case .waking?:
                    guard Date() < wakeDeadline else {
                        logger.error("\(who) didn't wake up fully")
                        fail("\(who) is asleep and didn't wake up fully; nothing was moved. Wake it and try again")
                        return false
                    }
                    logger.info("\(who) is waking up; waiting")
                    setStatus(.running("waking \(who)…"))
                    Thread.sleep(forTimeInterval: 1)
                    continue
                case .ready?, nil:
                    logger.info("ping ok: \(who)")
                }
            }
            break
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
        var destWentQuiet = false
        switch sendWatched("CONNECT \(macList)", timeout: 90) {
        case .failure(.stoppedAnswering):
            logger.error("\(dest) stopped answering during CONNECT (asleep?)")
            connectProblem = "\(dest) stopped answering (did it go to sleep?)"
            destWentQuiet = true
        case .failure(.request(let e)):
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
        //    Some peripherals (notably the Magic Mouse) occasionally report
        //    connected and then drop a moment later, so don't trust CONNECT
        //    alone. If CONNECT timed out the destination may still be busy,
        //    so allow VERIFY time to queue behind it.
        setStatus(.running("verifying…"))
        func verify(_ list: [String], timeout: TimeInterval) -> Set<String>? {
            switch send("VERIFY \(list.joined(separator: ","))", timeout: timeout) {
            case .success(let resp):
                logger.info("VERIFY: \(resp)")
                return PeripheralReport.decodeOK(resp).map { Set($0.filter(\.isConnected).map(\.mac)) }
            case .failure(let e):
                logger.warn("verify call failed: \(e)")
                return nil
            }
        }
        // Fall back to what CONNECT reported. If we know nothing, assume
        // nothing arrived.
        var arrived = (destWentQuiet ? nil : verify(macs, timeout: connectProblem == nil ? 10 : 30))
            ?? Set((connectReports ?? []).filter(\.isConnected).map(\.mac))
        var missing = macs.filter { !arrived.contains($0) }

        // 5. One more try for stragglers, as long as the destination is
        //    answering normally.
        if !missing.isEmpty, connectReports != nil {
            logger.warn("not on \(dest) yet: \(label(missing)); asking it to try again")
            setStatus(.running("retrying \(label(missing)) on \(dest)…"))
            switch sendWatched("CONNECT \(missing.joined(separator: ","))", timeout: 60) {
            case .success(let resp): logger.info("retry CONNECT response: \(resp)")
            case .failure(.stoppedAnswering):
                logger.error("\(dest) stopped answering during the retry (asleep?)")
                destWentQuiet = true
            case .failure(.request(let e)): logger.warn("retry CONNECT failed: \(e)")
            }
            if !destWentQuiet, let now = verify(macs, timeout: 10) { arrived = now }
            missing = macs.filter { !arrived.contains($0) }
        }

        if missing.isEmpty {
            logger.info("switch complete")
            setStatus(.success(Date()))
            return true
        }

        // 6. All or nothing: rather than leave the keyboard on one Mac and
        //    the mouse on the other, ask the destination to release what it
        //    got and bring everything back here.
        let reason = connectProblem ?? "\(label(missing)) didn't connect on \(dest)"
        logger.warn("\(reason); bringing all peripherals back to this Mac")
        // If it went quiet we don't know what it got, so ask it to release
        // everything; if it's asleep, it drops stale work when it wakes.
        let toRelease = destWentQuiet ? macs : macs.filter { arrived.contains($0) }
        if !toRelease.isEmpty {
            setStatus(.running("taking peripherals back from \(dest)…"))
            switch send("RELEASE \(toRelease.joined(separator: ","))", timeout: destWentQuiet ? 5 : 20) {
            case .success(let resp): logger.info("RELEASE response: \(resp)")
            case .failure(let e): logger.warn("couldn't ask \(dest) to release \(label(toRelease)): \(e)")
            }
        }

        // The peripherals may still be busy with the other Mac or dozing,
        // so keep trying for a while rather than once.
        setStatus(.running("reconnecting here…"))
        var stranded = macs.filter { !bluetooth.isReady($0) }
        let reconnectDeadline = Date().addingTimeInterval(Self.reconnectWait)
        var round = 0
        while !stranded.isEmpty {
            round += 1
            stranded = stranded.filter { mac in
                switch bluetooth.connect(mac) {
                case .success:
                    logger.info("  \(names[mac] ?? mac): reconnected here")
                    return false
                case .failure(let e):
                    logger.warn("  \(names[mac] ?? mac): couldn't reconnect here (try \(round)) - \(e)")
                    return true
                }
            }
            if stranded.isEmpty || Date() >= reconnectDeadline { break }
            Thread.sleep(forTimeInterval: 2)
        }
        for mac in stranded {
            logger.error("  \(names[mac] ?? mac): gave up reconnecting here")
        }

        if stranded.isEmpty {
            fail("\(reason); kept everything on this Mac. Try again")
        } else {
            fail("\(reason); couldn't reconnect \(label(stranded)) here. Wake it and click the icon again, or pair it in System Settings")
        }
        return false
    }

    /// How long to wait for a sleeping destination to wake fully.
    static let wakeWait: TimeInterval = 15
    /// How long to keep trying to take peripherals back after a failure.
    static let reconnectWait: TimeInterval = 20

    enum WatchedFailure: Error {
        case request(NetworkFailure)
        /// The destination stopped answering pings while the request ran.
        case stoppedAnswering
    }

    /// Sends a long-running request while pinging the destination every few
    /// seconds. A busy destination still answers ("ERR busy"); one that has
    /// gone to sleep doesn't, and then we stop waiting instead of sitting
    /// out the full timeout with no keyboard or mouse.
    private func sendWatched(_ command: String, to target: PeerTarget, timeout: TimeInterval) -> Result<String, WatchedFailure> {
        let done = DispatchSemaphore(value: 0)
        var result: Result<String, NetworkFailure>?
        DispatchQueue.global(qos: .userInitiated).async {
            result = NetworkClient.send(to: target, command: command, timeout: timeout)
            done.signal()
        }
        var missed = 0
        while done.wait(timeout: .now() + 5) == .timedOut {
            if case .failure = NetworkClient.send(to: target, command: "PING", timeout: 4) {
                missed += 1
                logger.warn("\(target.label) didn't answer a check-in (\(missed))")
                if missed >= 2 { return .failure(.stoppedAnswering) }
            } else {
                missed = 0
            }
        }
        return (result ?? .failure(.other("no result"))).mapError { .request($0) }
    }

    /// Sends clipboard text after a successful switch. Failures are logged
    /// but don't affect the switch.
    private func sendClipboard(_ text: String, to target: PeerTarget) {
        guard let command = Clipboard.command(for: text) else { return }
        switch NetworkClient.send(to: target, command: command, timeout: 10) {
        case .success(let resp) where resp == "OK clipboard":
            logger.info("sent clipboard text to \(target.label) (\(text.utf8.count) bytes)")
        case .success(let resp):
            logger.warn("clipboard not delivered: \(BTProtocol.describe(response: resp))")
        case .failure(let e):
            logger.warn("clipboard not delivered: \(e)")
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
