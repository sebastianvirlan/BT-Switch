import Foundation
import Combine

/// The one Mac this Mac is paired with, persisted in the Keychain.
///
/// Readable from any thread (`current`); `peer` is the @Published mirror
/// for SwiftUI and is only updated on the main queue.
final class PairingStore: ObservableObject {
    static let shared = PairingStore()

    @Published private(set) var peer: PairedPeer?

    private let lock = NSLock()
    private var stored: PairedPeer?
    private let account = "pairing"
    private let logger = AppLogger.shared

    private init() {
        if let data = Keychain.read(account: account) {
            stored = try? JSONDecoder().decode(PairedPeer.self, from: data)
        }
        peer = stored
    }

    /// Thread-safe snapshot.
    var current: PairedPeer? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// Key for a sender ID, if it's the paired Mac. Used by the server.
    func key(for senderID: String) -> Data? {
        guard let p = current, p.id == senderID else { return nil }
        return p.key
    }

    func save(_ newPeer: PairedPeer) {
        lock.lock()
        stored = newPeer
        lock.unlock()
        let saved = (try? JSONEncoder().encode(newPeer)).map { Keychain.write(account: account, data: $0) } ?? false
        if !saved {
            logger.error("could not save pairing to Keychain")
        }
        publish()
    }

    func clear() {
        lock.lock()
        stored = nil
        lock.unlock()
        Keychain.delete(account: account)
        publish()
    }

    /// Remembers where the paired Mac was last reached, as a fallback for
    /// when Bonjour can't find it.
    func updateAddress(_ address: String, for id: String) {
        lock.lock()
        guard var p = stored, p.id == id, p.address != address else { lock.unlock(); return }
        p.address = address
        lock.unlock()
        save(p)
    }

    private func publish() {
        let snapshot = current
        DispatchQueue.main.async { [weak self] in self?.peer = snapshot }
    }
}
