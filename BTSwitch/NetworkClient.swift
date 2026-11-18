import Foundation
import Network

/// Where and how to reach the paired Mac.
struct PeerTarget {
    let endpoint: NWEndpoint
    /// Shown in messages: the other Mac's name.
    let label: String
    let key: Data
}

extension NetworkFailure {
    /// Maps a Network.framework error to a user-facing cause.
    static func from(_ error: NWError, connection: NWConnection, label: String) -> NetworkFailure {
        // macOS reports a Local Network privacy denial on the path.
        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
            return .localNetworkDenied
        }
        switch error {
        case .posix(let code):
            return NetworkFailure.from(posix: code, host: label)
                ?? .other("connecting to \(label) failed: \(error.localizedDescription)")
        case .dns:
            return .cannotResolve(host: label)
        default:
            return .other("connecting to \(label) failed: \(error.localizedDescription)")
        }
    }
}

/// Client side of the BT-SWITCH/3 command protocol (see Protocol.swift).
final class NetworkClient {
    /// Sends one signed request to the paired Mac and returns the
    /// single-line response. Blocks until done or timeout; caller must NOT
    /// be on the main thread.
    static func send(to target: PeerTarget, command: String,
                     timeout: TimeInterval = 30.0) -> Result<String, NetworkFailure> {
        let label = target.label
        let conn = NWConnection(to: target.endpoint, using: .tcp)
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

        func receiveLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, err in
                if let err = err {
                    finish(.failure(.other("lost connection to \(label) while waiting for a reply: \(err.localizedDescription)")))
                    return
                }
                if let data = data { responseBuffer.append(data) }
                if let (lines, _) = BTProtocol.extractLines(responseBuffer, count: 1) {
                    finish(.success(lines[0]))
                    return
                }
                if isComplete {
                    if let s = String(data: responseBuffer, encoding: .utf8), !s.isEmpty {
                        finish(.success(s.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        finish(.failure(.other("\(label) closed the connection without replying; is something other than BTSwitch on that port?")))
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
                let req = BTProtocol.makeRequest(senderID: AppInfo.instanceID, key: target.key, command: command)
                conn.send(content: Data(req.utf8), completion: .contentProcessed { err in
                    if let err = err {
                        finish(.failure(.other("sending to \(label) failed: \(err.localizedDescription)")))
                    }
                })
                receiveLoop()
            case .failed(let e), .waiting(let e):
                // .waiting: NWConnection would keep retrying until our
                // timeout, so fail fast with the reason instead.
                finish(.failure(.from(e, connection: conn, label: label)))
            default:
                break
            }
        }

        conn.start(queue: queue)

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); let connected = didConnect; lock.unlock()
            finish(.failure(connected
                ? .noResponse(host: label, seconds: Int(timeout))
                : .connectTimeout(host: label)))
        }

        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(.connectTimeout(host: label))
    }
}

/// Line-oriented wrapper around an NWConnection for the multi-step pairing
/// exchange. All callbacks run on `queue`, which must be the queue the
/// connection was started on.
final class LineChannel {
    let connection: NWConnection
    let label: String
    private let queue: DispatchQueue
    private var buffer: Data

    init(connection: NWConnection, label: String, queue: DispatchQueue, buffer: Data = Data()) {
        self.connection = connection
        self.label = label
        self.queue = queue
        self.buffer = buffer
    }

    func send(_ line: String, completion: @escaping (NetworkFailure?) -> Void = { _ in }) {
        let text = line.hasSuffix("\n") ? line : line + "\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [label] err in
            completion(err.map { .other("sending to \(label) failed: \($0.localizedDescription)") })
        })
    }

    /// Reads one line, failing after `timeout` seconds.
    func readLine(timeout: TimeInterval, completion: @escaping (Result<String, NetworkFailure>) -> Void) {
        var done = false
        let finish: (Result<String, NetworkFailure>) -> Void = { r in
            guard !done else { return }
            done = true
            completion(r)
        }
        let timer = DispatchWorkItem { [label] in
            finish(.failure(.noResponse(host: label, seconds: Int(timeout))))
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        readMore { r in
            timer.cancel()
            finish(r)
        }
    }

    private func readMore(_ completion: @escaping (Result<String, NetworkFailure>) -> Void) {
        if let (lines, rest) = BTProtocol.extractLines(buffer, count: 1) {
            buffer = rest
            completion(.success(lines[0]))
            return
        }
        if buffer.count > BTProtocol.maxRequestBytes {
            completion(.failure(.other("\(label) sent an oversized message")))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, err in
            guard let self = self else { return }
            if let err = err {
                completion(.failure(.other("lost connection to \(self.label): \(err.localizedDescription)")))
                return
            }
            if let d = data { self.buffer.append(d) }
            if let (lines, rest) = BTProtocol.extractLines(self.buffer, count: 1) {
                self.buffer = rest
                completion(.success(lines[0]))
            } else if isComplete {
                completion(.failure(.other("\(self.label) closed the connection")))
            } else {
                self.readMore(completion)
            }
        }
    }

    /// Calls `onClose` if the other side hangs up (or the connection fails).
    func watchForClose(_ onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, err in
            if isComplete || err != nil { onClose() }
        }
    }
}
