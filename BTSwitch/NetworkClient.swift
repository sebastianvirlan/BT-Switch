import Foundation
import Network

/// Client side of the BT-SWITCH/1 protocol.
final class NetworkClient {
    enum Failure: Error, CustomStringConvertible {
        case invalidHost(String)
        case connectFailed(String)
        case sendFailed(String)
        case receiveFailed(String)
        case timeout
        case rejected(String)
        case malformed(String)

        var description: String {
            switch self {
            case .invalidHost(let s): return "invalid host: \(s)"
            case .connectFailed(let s): return "connect failed: \(s)"
            case .sendFailed(let s): return "send failed: \(s)"
            case .receiveFailed(let s): return "receive failed: \(s)"
            case .timeout: return "timeout"
            case .rejected(let s): return "destination rejected: \(s)"
            case .malformed(let s): return "malformed response: \(s)"
            }
        }
    }

    /// Sends one request, returns the single-line response.
    /// Synchronous (blocks until done or timeout). Caller must NOT be on main thread.
    static func send(host: String, port: Int, command: String, token: String, timeout: TimeInterval = 30.0) -> Result<String, Failure> {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .failure(.invalidHost("port \(port)"))
        }
        let nwHost = NWEndpoint.Host(host)
        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "com.user.btswitch.client.\(UUID().uuidString)")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Failure> = .failure(.timeout)
        var responseBuffer = Data()
        var didFinish = false
        let lock = NSLock()

        func finish(_ r: Result<String, Failure>) {
            lock.lock()
            defer { lock.unlock() }
            if didFinish { return }
            didFinish = true
            result = r
            conn.cancel()
            semaphore.signal()
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let req = "BT-SWITCH/1\nTOKEN \(token)\n\(command)\n"
                conn.send(content: req.data(using: .utf8), completion: .contentProcessed { err in
                    if let err = err {
                        finish(.failure(.sendFailed(err.localizedDescription)))
                    }
                })
                receiveLoop()
            case .failed(let e):
                finish(.failure(.connectFailed(e.localizedDescription)))
            case .cancelled:
                // If we hit cancelled before reading anything, surface as timeout/closed.
                break
            default: break
            }
        }

        func receiveLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, err in
                if let err = err {
                    finish(.failure(.receiveFailed(err.localizedDescription)))
                    return
                }
                if let data = data { responseBuffer.append(data) }
                if let s = String(data: responseBuffer, encoding: .utf8),
                   s.contains("\n") {
                    // First line is the response.
                    let line = s.split(separator: "\n", omittingEmptySubsequences: false)[0]
                    finish(.success(String(line)))
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

        conn.start(queue: queue)

        // Wait with timeout.
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            finish(.failure(.timeout))
        }

        return result
    }
}
