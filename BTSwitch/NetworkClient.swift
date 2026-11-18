import Foundation
import Network

/// Client side of the BT-SWITCH/2 protocol (see Protocol.swift).
final class NetworkClient {
    /// Sends one signed request, returns the single-line response.
    /// Synchronous (blocks until done or timeout). Caller must NOT be on main thread.
    static func send(host: String, port: Int, command: String, token: String,
                     timeout: TimeInterval = 30.0) -> Result<String, NetworkFailure> {
        guard let rawPort = BTProtocol.port(from: port),
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            return .failure(.invalidAddress("port \(port)"))
        }
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(.invalidAddress("(empty)")) }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "\(AppInfo.bundleID).client")

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<String, NetworkFailure>?
        var didConnect = false
        var responseBuffer = Data()   // only touched on `queue`

        func finish(_ r: Result<String, NetworkFailure>) {
            lock.lock()
            defer { lock.unlock() }
            if result != nil { return }
            result = r
            conn.cancel()
            semaphore.signal()
        }

        func failure(for error: NWError) -> NetworkFailure {
            // macOS reports a Local Network privacy denial on the path.
            if conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                return .localNetworkDenied
            }
            switch error {
            case .posix(let code):
                return NetworkFailure.from(posix: code, host: host, port: port)
                    ?? .other("connect to \(host) failed: \(error.localizedDescription)")
            case .dns:
                return .cannotResolve(host: host)
            default:
                return .other("connect to \(host) failed: \(error.localizedDescription)")
            }
        }

        func receiveLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, err in
                if let err = err {
                    finish(.failure(.other("lost connection to \(host) while waiting for a reply: \(err.localizedDescription)")))
                    return
                }
                if let data = data { responseBuffer.append(data) }
                if let s = String(data: responseBuffer, encoding: .utf8), s.contains("\n") {
                    // First line is the response.
                    let line = s.split(separator: "\n", omittingEmptySubsequences: false)[0]
                    finish(.success(String(line).trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }
                if isComplete {
                    if let s = String(data: responseBuffer, encoding: .utf8), !s.isEmpty {
                        finish(.success(s.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        finish(.failure(.other("\(host) closed the connection without replying; is something other than BTSwitch on port \(port)?")))
                    }
                    return
                }
                receiveLoop()
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                lock.lock(); didConnect = true; lock.unlock()
                let req = BTProtocol.makeRequest(token: token, command: command)
                conn.send(content: Data(req.utf8), completion: .contentProcessed { err in
                    if let err = err {
                        finish(.failure(.other("sending to \(host) failed: \(err.localizedDescription)")))
                    }
                })
                receiveLoop()
            case .failed(let e):
                finish(.failure(failure(for: e)))
            case .waiting(let e):
                // e.g. connection refused / no route; NWConnection would keep
                // retrying until our timeout, so fail fast instead.
                finish(.failure(failure(for: e)))
            default:
                break
            }
        }

        conn.start(queue: queue)

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); let connected = didConnect; lock.unlock()
            finish(.failure(connected
                ? .noResponse(host: host, seconds: Int(timeout))
                : .connectTimeout(host: host)))
        }

        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(.connectTimeout(host: host))
    }
}
