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
    private let bluetooth: BluetoothController
    private let logger: AppLogger
    private let switchLock: SwitchLock
    private let workQueue = DispatchQueue(label: "\(AppInfo.bundleID).coordinator", qos: .userInitiated)

    init(settings: AppSettings, bluetooth: BluetoothController, logger: AppLogger, switchLock: SwitchLock) {
        self.settings = settings
        self.bluetooth = bluetooth
        self.logger = logger
        self.switchLock = switchLock
    }

    /// True while a switch started from this Mac is in flight.
    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// Kick off a switch. Non-blocking — observe `status` for progress.
    func switchToDestination() {
        let dest = settings.destination.trimmingCharacters(in: .whitespaces)
        let macs = settings.peripherals
        let token = settings.token
        let port = settings.port

        guard !dest.isEmpty else { return fail("destination not configured") }
        guard !macs.isEmpty else { return fail("no peripherals configured") }
        guard !token.isEmpty else { return fail("no token configured") }

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
            self.runSwitch(dest: dest, port: port, macs: macs, token: token)
        }
    }

    private func runSwitch(dest: String, port: Int, macs: [String], token: String) {
        func send(_ command: String, timeout: TimeInterval) -> Result<String, NetworkClient.Failure> {
            NetworkClient.send(host: dest, port: port, command: command, token: token, timeout: timeout)
        }
        let macList = macs.joined(separator: ",")

        // 1. Ping the destination BEFORE removing anything locally, so an
        //    unreachable/misconfigured/busy destination can't strand the
        //    peripherals.
        switch send("PING", timeout: 5) {
        case .failure(let e):
            logger.error("ping failed: \(e)")
            return fail("can't reach \(dest): \(e)")
        case .success(let resp) where resp == "OK pong":
            logger.info("ping ok")
        case .success(let resp):
            logger.error("ping unexpected response: \(resp)")
            return fail(Self.describe(response: resp))
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
                connectProblem = Self.describe(response: resp)
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

    private static func describe(response: String) -> String {
        if let code = BTProtocol.errorCode(in: response) {
            return BTProtocol.describe(errorCode: code)
        }
        return "unexpected response: \(response)"
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
