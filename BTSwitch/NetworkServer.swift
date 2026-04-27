import Foundation
import Network

/// TCP listener implementing the BT-SWITCH/1 protocol.
///
/// Wire protocol (line-delimited UTF-8):
///   line 1: BT-SWITCH/1
///   line 2: TOKEN <shared_secret>
///   line 3: <command>
///
/// Commands:
///   PING                       -> "OK pong"
///   CONNECT <mac1>,<mac2>,...  -> connect peripherals
///   VERIFY  <mac1>,<mac2>,...  -> report connection status
final class NetworkServer {
    private let settings: AppSettings
    private let bluetooth: BluetoothController
    private let logger: AppLogger
    private var listener: NWListener?
    private let acceptQueue = DispatchQueue(label: "com.user.btswitch.server.accept")
    private let workQueue = DispatchQueue(label: "com.user.btswitch.server.work", qos: .userInitiated)

    init(settings: AppSettings, bluetooth: BluetoothController, logger: AppLogger) {
        self.settings = settings
        self.bluetooth = bluetooth
        self.logger = logger
    }

    func start() throws {
        let port = NWEndpoint.Port(rawValue: UInt16(settings.port)) ?? 52525
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        let l = try NWListener(using: params, on: port)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("listener ready on port \(port.rawValue)")
            case .failed(let e):
                self?.logger.error("listener failed: \(e.localizedDescription)")
            case .cancelled:
                self?.logger.info("listener cancelled")
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

    // MARK: - Connection handling

    private func handle(connection conn: NWConnection) {
        conn.start(queue: acceptQueue)
        receiveRequest(conn: conn)
    }

    /// Read up to ~4KB looking for three newline-terminated lines, then dispatch.
    private func receiveRequest(conn: NWConnection, accumulated: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.warn("receive error: \(error.localizedDescription)")
                conn.cancel()
                return
            }

            var buf = accumulated
            if let d = data { buf.append(d) }

            // Look for three newlines. Any line ending (LF, CRLF) is OK.
            if let str = String(data: buf, encoding: .utf8) {
                let lines = str.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count >= 3 {
                    let line1 = String(lines[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let line2 = String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let line3 = String(lines[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.dispatch(conn: conn, line1: line1, line2: line2, line3: line3)
                    return
                }
            }

            if isComplete {
                self.respond(conn: conn, "ERR incomplete_request\n")
                return
            }

            if buf.count > 4096 {
                self.respond(conn: conn, "ERR too_long\n")
                return
            }

            // Keep reading.
            self.receiveRequest(conn: conn, accumulated: buf)
        }
    }

    private func dispatch(conn: NWConnection, line1: String, line2: String, line3: String) {
        if line1 != "BT-SWITCH/1" {
            logger.warn("rejected: bad protocol line: \(line1)")
            respond(conn: conn, "ERR bad_protocol\n")
            return
        }
        guard line2.hasPrefix("TOKEN "),
              String(line2.dropFirst("TOKEN ".count)) == settings.token,
              !settings.token.isEmpty else {
            logger.warn("rejected: bad token")
            respond(conn: conn, "ERR bad_token\n")
            return
        }

        switch line3 {
        case "PING":
            logger.info("ping")
            respond(conn: conn, "OK pong\n")

        case let s where s.hasPrefix("VERIFY "):
            let macs = parseMacs(String(s.dropFirst("VERIFY ".count)))
            logger.info("verify: \(macs)")
            workQueue.async { [weak self] in
                guard let self = self else { return }
                let parts = macs.map { mac in
                    let connected = self.bluetooth.isConnected(mac)
                    return "{\"mac\":\"\(mac)\",\"connected\":\(connected)}"
                }
                self.respond(conn: conn, "OK [\(parts.joined(separator: ","))]\n")
            }

        case let s where s.hasPrefix("CONNECT "):
            let macs = parseMacs(String(s.dropFirst("CONNECT ".count)))
            logger.info("connect: \(macs)")
            workQueue.async { [weak self] in
                self?.handleConnect(conn: conn, macs: macs)
            }

        default:
            logger.warn("unknown command: \(line3)")
            respond(conn: conn, "ERR bad_command\n")
        }
    }

    private func handleConnect(conn: NWConnection, macs: [String]) {
        var parts: [String] = []
        for mac in macs {
            if bluetooth.isConnected(mac) {
                logger.info("  \(mac): already connected")
                parts.append("{\"mac\":\"\(mac)\",\"status\":\"already_connected\"}")
                continue
            }
            // Up to 3 attempts.
            var ok = false
            var lastErr: BluetoothController.ConnectError?
            for attempt in 1...3 {
                let r = bluetooth.connect(mac)
                switch r {
                case .success:
                    logger.info("  \(mac): connected (attempt \(attempt))")
                    parts.append("{\"mac\":\"\(mac)\",\"status\":\"connected\",\"attempts\":\(attempt)}")
                    ok = true
                case .failure(let e):
                    lastErr = e
                    logger.warn("  \(mac): attempt \(attempt) failed - \(e)")
                    if attempt < 3 { Thread.sleep(forTimeInterval: 2) }
                }
                if ok { break }
            }
            if !ok {
                let reason = lastErr.map { "\($0)" } ?? "unknown"
                let escaped = reason.replacingOccurrences(of: "\"", with: "\\\"")
                parts.append("{\"mac\":\"\(mac)\",\"status\":\"failed\",\"error\":\"\(escaped)\"}")
            }
        }
        respond(conn: conn, "OK [\(parts.joined(separator: ","))]\n")
    }

    private func parseMacs(_ csv: String) -> [String] {
        csv.split(separator: ",").map {
            AppSettings.normalizeMAC($0.trimmingCharacters(in: .whitespaces))
        }.filter { AppSettings.isValidMAC($0) }
    }

    private func respond(conn: NWConnection, _ s: String) {
        let data = s.data(using: .utf8) ?? Data()
        conn.send(content: data, completion: .contentProcessed { _ in
            // Half-close so the client knows we're done.
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
        })
    }
}
