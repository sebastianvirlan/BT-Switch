import Foundation
import Network
import Combine

/// Finds other Macs running BTSwitch on the local network via Bonjour.
final class PeerDirectory: ObservableObject {
    struct Discovered: Identifiable, Equatable {
        let id: String          // the other Mac's instance ID (from the TXT record)
        let name: String
        let endpoint: NWEndpoint
    }

    @Published private(set) var peers: [Discovered] = []

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).browser")
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
    }

    func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: BTProtocol.bonjourType, domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                self?.logger.warn("network discovery failed: \(e.localizedDescription)")
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Discovered] = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint,
                      case .bonjour(let txt) = r.metadata,
                      let id = txt["id"], id != AppInfo.instanceID
                else { return nil }
                return Discovered(id: id, name: txt["name"] ?? name, endpoint: r.endpoint)
            }
            // The same Mac can appear once per interface (Wi-Fi + Ethernet).
            var seen = Set<String>()
            let unique = found.sorted { $0.name < $1.name }.filter { seen.insert($0.id).inserted }
            DispatchQueue.main.async { self?.peers = unique }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Where to reach the paired Mac: its Bonjour service if visible (follows
    /// IP changes), otherwise its last known address. Call on main.
    func endpoint(for peer: PairedPeer, port: Int) -> NWEndpoint? {
        if let d = peers.first(where: { $0.id == peer.id }) {
            return d.endpoint
        }
        if let addr = peer.address, !addr.isEmpty,
           let raw = BTProtocol.port(from: port), let p = NWEndpoint.Port(rawValue: raw) {
            return .hostPort(host: NWEndpoint.Host(addr), port: p)
        }
        return nil
    }
}
