import Foundation
import Network

/// Client side of the BT-SWITCH/2 protocol (see Protocol.swift).
final class NetworkClient {
    enum Failure: Error, CustomStringConvertible {
        case invalidHost(String)
        case connectFailed(String)
        case sendFailed(String)
        case receiveFailed(String)
        case timeout

        var description: String {
            switch self {
            case .invalidHost(let s): return "invalid host: \(s)"
            case .connectFailed(let s): return "connect failed: \(s)"
            case .sendFailed(let s): return "send failed: \(s)"
            case .receiveFailed(let s): return "receive failed: \(s)"
            case .timeout: return "timeout"
            }
        }
    }

    /// Sends one signed request, returns the single-line response.
    /// Synchronous (blocks until done or timeout). Caller must NOT be on main thread.
    static func send(host: String, port: Int, command: String, token: String, timeout: TimeInterval = 30.0) -> Result<String, Failure> {
        guard let rawPort = BTProtocol.port(from: port),
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            return .failure(.invalidHost("port \(port)"))
        }
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(.invalidHost("(empty)")) }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "\(AppInfo.bundleID).client")

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<String, Failure> = .failure(.timeout)
        var didFinish = false
        var responseBuffer = Data()   // only touched on `queue`

        func finish(_ r: Result<String, Failure>) {
            lock.lock()
            defer { lock.unlock() }
            if didFinish { return }
            didFinish = true
            result = r
            conn.cancel()
            semaphore.signal()
        }

        func receiveLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, err in
                if let err = err {
                    finish(.failure(.receiveFailed(err.localizedDescription)))
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
                        finish(.failure(.receiveFailed("empty response")))
                    }
                    return
                }
                receiveLoop()
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let req = BTProtocol.makeRequest(token: token, command: command)
                conn.send(content: Data(req.utf8), completion: .contentProcessed { err in
                    if let err = err {
                        finish(.failure(.sendFailed(err.localizedDescription)))
                    }
                })
                receiveLoop()
            case .failed(let e):
                finish(.failure(.connectFailed(e.localizedDescription)))
            case .waiting(let e):
                // e.g. connection refused / no route; NWConnection would keep
                // retrying until our timeout, so fail fast instead.
                finish(.failure(.connectFailed(e.localizedDescription)))
            default:
                break
            }
        }

        conn.start(queue: queue)

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finish(.failure(.timeout))
        }

        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
