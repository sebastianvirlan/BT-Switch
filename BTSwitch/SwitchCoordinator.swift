import Foundation
import Combine
import AppKit

/// Coordinates a single switch: PING → remove on source → CONNECT on destination → VERIFY.
///
/// Public API is callable from any thread; internally we marshal state mutations
/// onto the main queue so SwiftUI bindings are happy.
final class SwitchCoordinator: ObservableObject {
    enum Status: Equatable {
        case idle
        case running(String)   // human-readable phase
        case success
        case failure(String)
    }

    @Published private(set) var status: Status = .idle

    private let settings: AppSettings
    private let bluetooth: BluetoothController
    private let logger: AppLogger
    private let workQueue = DispatchQueue(label: "com.user.btswitch.coordinator", qos: .userInitiated)

    init(settings: AppSettings, bluetooth: BluetoothController, logger: AppLogger) {
        self.settings = settings
        self.bluetooth = bluetooth
        self.logger = logger
    }

    /// True iff a switch is currently in flight.
    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// Kick off a switch. Non-blocking — observe `status` for progress.
    func switchToDestination() {
        if isRunning {
            logger.warn("switch already in progress, ignoring")
            return
        }

        let dest = settings.destination.trimmingCharacters(in: .whitespaces)
        let macs = settings.peripherals
        let token = settings.token
        let port = settings.port

        guard !dest.isEmpty else {
            setStatus(.failure("destination not configured"))
            return
        }
        guard !macs.isEmpty else {
            setStatus(.failure("no peripherals configured"))
            return
        }
        guard !token.isEmpty else {
            setStatus(.failure("no token configured"))
            return
        }

        setStatus(.running("pinging \(dest)…"))
        logger.info("switch start: dest=\(dest) macs=\(macs)")

        workQueue.async { [weak self] in
            self?.runSwitch(dest: dest, port: port, macs: macs, token: token)
        }
    }

    private func runSwitch(dest: String, port: Int, macs: [String], token: String) {
        // 1. Ping the destination so we know it's reachable BEFORE we
        //    remove anything locally. This avoids the disaster scenario
        //    where we unregister peripherals from the source but the
        //    destination is unreachable.
        let pingResult = NetworkClient.send(host: dest, port: port, command: "PING", token: token, timeout: 5)
        switch pingResult {
        case .failure(let e):
            logger.error("ping failed: \(e)")
            setStatus(.failure("can't reach \(dest): \(e)"))
            return
        case .success(let resp):
            guard resp == "OK pong" else {
                logger.error("ping unexpected response: \(resp)")
                let reason: String
                if resp.hasPrefix("ERR ") {
                    reason = "destination rejected: \(resp.dropFirst(4))"
                } else {
                    reason = "unexpected response: \(resp)"
                }
                setStatus(.failure(reason))
                return
            }
            logger.info("ping ok")
        }

        // 2. Remove peripherals locally.
        setStatus(.running("removing locally…"))
        for mac in macs {
            let ok = bluetooth.remove(mac)
            logger.info("  remove \(mac): \(ok ? "ok" : "no-op")")
        }

        // 3. Send CONNECT to destination. Allow more time — pairing + connect
        //    for two devices can take 10–20 seconds.
        setStatus(.running("connecting on \(dest)…"))
        let connectResult = NetworkClient.send(
            host: dest, port: port,
            command: "CONNECT \(macs.joined(separator: ","))",
            token: token,
            timeout: 60
        )
        switch connectResult {
        case .failure(let e):
            logger.error("CONNECT failed: \(e)")
            setStatus(.failure("connect on destination failed: \(e)"))
            return
        case .success(let resp):
            logger.info("CONNECT response: \(resp)")
            if resp.hasPrefix("ERR ") {
                setStatus(.failure("destination rejected: \(resp.dropFirst(4))"))
                return
            }
        }

        // 4. Verify (optional but cheap).
        setStatus(.running("verifying…"))
        let verifyResult = NetworkClient.send(
            host: dest, port: port,
            command: "VERIFY \(macs.joined(separator: ","))",
            token: token,
            timeout: 10
        )
        switch verifyResult {
        case .success(let resp):
            logger.info("VERIFY: \(resp)")
            if resp.contains("\"connected\":false") {
                setStatus(.failure("at least one peripheral did not connect; see log"))
                return
            }
        case .failure(let e):
            // Verify failure isn't fatal — the connect probably worked.
            logger.warn("verify call failed: \(e) (handoff likely succeeded anyway)")
        }

        logger.info("switch complete")
        setStatus(.success)
    }

    private func setStatus(_ new: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = new
        }
    }
}
