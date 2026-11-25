import Foundation
import IOBluetooth

/// Wraps the IOBluetooth primitives we need.
///
/// Every IOBluetooth call — reads included — is funneled through one
/// dedicated serial queue, so the framework is never used from two threads
/// at once. This is also what keeps IOBluetoothDevicePair.start() working:
/// its delegate callbacks must not be blocked by openConnection(), which
/// blocks its caller until the radio handshake completes. Doing this on the
/// main thread would also freeze the UI.
///
/// Synchronous methods block the caller (sometimes for seconds) and must not
/// be called from the main thread or from the internal queue. UI code uses
/// the async `connectedCount` instead.
final class BluetoothController {
    enum ConnectError: Error, CustomStringConvertible {
        case bluetoothOff
        case deviceNotFound(String)
        case invalidRSSI(String)
        case pairInitFailed(String)
        case pairStartFailed(String, IOReturn)
        case openConnectionFailed(String, IOReturn)
        case notConnectedAfterOpen(String)
        case connectedButNotPaired(String)

        var description: String {
            switch self {
            case .bluetoothOff: return "Bluetooth is off"
            case .deviceNotFound(let m): return "device not found: \(m)"
            case .invalidRSSI(let m): return "\(m) asleep or out of range; press a key / click to wake it"
            case .pairInitFailed(let m): return "could not initialise pairing for \(m)"
            case .pairStartFailed(let m, let rc): return "pair start failed for \(m): 0x\(String(rc, radix: 16))"
            case .openConnectionFailed(let m, let rc): return "openConnection failed for \(m): 0x\(String(rc, radix: 16))"
            case .notConnectedAfterOpen(let m): return "openConnection ok but \(m) not reporting connected"
            case .connectedButNotPaired(let m): return "\(m) connected but pairing didn't complete"
            }
        }
    }

    enum RemoveResult: Equatable, CustomStringConvertible {
        case removed
        case disconnected       // wasn't paired, but held a half-made link; closed it
        case notPaired          // nothing to do
        case stillPaired        // `remove` ran but the device is still paired
        case unsupported        // private selector missing (macOS changed)
        case deviceNotFound

        var description: String {
            switch self {
            case .removed: return "removed"
            case .disconnected: return "dropped a half-made connection"
            case .notPaired: return "not paired (no-op)"
            case .stillPaired: return "remove had no effect; device still paired"
            case .unsupported: return "remove API unavailable on this macOS version"
            case .deviceNotFound: return "device not found"
            }
        }

        var isFailure: Bool { self == .stillPaired || self == .unsupported }
    }

    private static let invalidRSSI: Int8 = 127
    /// How long to wait for the link to come up after openConnection.
    private static let connectWait: TimeInterval = 5
    /// How long to wait for pairing to finish once the link is up.
    private static let pairingWait: TimeInterval = 15
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).bluetooth", qos: .userInitiated)

    // MARK: - Reads

    /// Connected *and* paired. A device connected without a completed
    /// pairing works until it idles, then can't reconnect, so only this
    /// counts as "arrived".
    func isReady(_ mac: String) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            guard let d = Self.device(mac) else { return false }
            return d.isConnected() && d.isPaired()
        }
    }

    func isPoweredOn() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { Self.isPoweredOn }
    }

    func isConnected(_ mac: String) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { Self.device(mac)?.isConnected() ?? false }
    }

    /// Counts connected peripherals without blocking the caller. The
    /// completion runs on the main queue. If a connect is in progress the
    /// answer arrives once it finishes.
    func connectedCount(_ macs: [String], completion: @escaping (Int) -> Void) {
        queue.async {
            let n = macs.filter { Self.device($0)?.isConnected() ?? false }.count
            DispatchQueue.main.async { completion(n) }
        }
    }

    /// Orders peripherals keyboard, trackpad, other, mouse: the mouse is the
    /// slowest and least reliable to pair, so it shouldn't hold the others up.
    /// macOS can forget a removed device's name, so `names` (what BTSwitch
    /// remembered from the picker) is the fallback.
    func sortedForConnecting(_ macs: [String], names: [String: String] = [:]) -> [String] {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let ranks: [String: Int] = queue.sync {
            Dictionary(macs.map { mac -> (String, Int) in
                let d = Self.device(mac)
                let name = d?.name ?? names[mac] ?? ""
                let kind = d.map { Self.kind(of: $0, name: name) } ?? Self.kind(name: name)
                return (mac, kind.connectOrder)
            }, uniquingKeysWith: { a, _ in a })
        }
        return macs.enumerated()
            .sorted { (ranks[$0.element] ?? 2, $0.offset) < (ranks[$1.element] ?? 2, $1.offset) }
            .map(\.element)
    }

    struct PairedDevice: Identifiable, Equatable {
        enum Kind { case keyboard, mouse, trackpad, other }
        let address: String     // normalised, e.g. "10:94:bb:b9:73:74"
        let name: String
        let kind: Kind
        let isConnected: Bool
        var id: String { address }
    }

    /// Lists the Bluetooth devices paired with this Mac, without blocking
    /// the caller. The completion runs on the main queue.
    func pairedDevices(completion: @escaping ([PairedDevice]) -> Void) {
        queue.async {
            let devices = (IOBluetoothDevice.pairedDevices() ?? [])
                .compactMap { $0 as? IOBluetoothDevice }
                .compactMap { d -> PairedDevice? in
                    guard let addr = d.addressString else { return nil }
                    let name = d.name ?? d.nameOrAddress ?? addr
                    return PairedDevice(address: MAC.normalize(addr), name: name,
                                        kind: Self.kind(of: d, name: name), isConnected: d.isConnected())
                }
                .sorted { ($0.kind.sortOrder, $0.name) < ($1.kind.sortOrder, $1.name) }
            DispatchQueue.main.async { completion(devices) }
        }
    }

    private static func kind(name: String) -> PairedDevice.Kind {
        let lower = name.lowercased()
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("mouse") { return .mouse }
        return .other
    }

    private static func kind(of d: IOBluetoothDevice, name: String) -> PairedDevice.Kind {
        let lower = name.lowercased()
        if lower.contains("trackpad") { return .trackpad }
        // Class of Device: major 0x05 = peripheral; minor bit 0x10 keyboard, 0x20 pointer.
        if d.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral) {
            let minor = d.deviceClassMinor
            if minor & 0x10 != 0 { return .keyboard }
            if minor & 0x20 != 0 { return .mouse }
        }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("mouse") { return .mouse }
        return .other
    }

    // MARK: - Mutating ops

    /// Pair-and-connect. Synchronous.
    func connect(_ mac: String) -> Result<Void, ConnectError> {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { self.doConnect(mac) }
    }

    /// Hard unregister via the private "remove" selector, then confirm the
    /// device is really gone. Synchronous.
    func remove(_ mac: String) -> RemoveResult {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            guard let device = Self.device(mac) else { return .deviceNotFound }
            if !device.isPaired() {
                // Connected without a finished pairing still holds the
                // peripheral's link, so the other Mac can't take it. Let go.
                if device.isConnected() {
                    device.closeConnection()
                    return .disconnected
                }
                return .notPaired
            }
            let sel = NSSelectorFromString("remove")
            guard device.responds(to: sel) else { return .unsupported }
            _ = device.perform(sel)

            // The unpair is asynchronous inside bluetoothd; give it a moment.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if !device.isPaired() { return .removed }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return .stillPaired
        }
    }

    // MARK: - Internal (run on `queue` only)

    private static func device(_ mac: String) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: mac)
    }

    private static var isPoweredOn: Bool {
        guard let host = IOBluetoothHostController.default() else { return false }
        return host.powerState != kBluetoothHCIPowerStateOFF
    }

    private func doConnect(_ mac: String) -> Result<Void, ConnectError> {
        guard Self.isPoweredOn else { return .failure(.bluetoothOff) }
        guard let device = Self.device(mac) else {
            return .failure(.deviceNotFound(mac))
        }

        // Hard guard: invalid RSSI means the peripheral isn't responding.
        if device.rssi() == Self.invalidRSSI {
            return .failure(.invalidRSSI(mac))
        }

        // A half-finished earlier attempt can leave the device connected
        // but unpaired; drop that link so pairing starts from scratch.
        if device.isConnected() && !device.isPaired() {
            device.closeConnection()
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard let devicePair = IOBluetoothDevicePair(device: device) else {
            return .failure(.pairInitFailed(mac))
        }
        let delegate = PairDelegate()
        devicePair.delegate = delegate

        // Keep the pair object and its delegate alive until we are done
        // polling, since pairing callbacks can still arrive meanwhile.
        return withExtendedLifetime((devicePair, delegate)) {
            let pairRC = devicePair.start()
            if pairRC != kIOReturnSuccess {
                return .failure(.pairStartFailed(mac, pairRC))
            }

            // openConnection blocks while the radio handshake completes.
            let openRC = device.openConnection()
            if openRC != kIOReturnSuccess {
                return .failure(.openConnectionFailed(mac, openRC))
            }

            // isConnected / isPaired can lag. Poll until both are true:
            // connected-but-unpaired looks fine now but the device won't
            // reconnect after it sleeps. The Magic Mouse in particular can
            // take well over 5s to finish pairing once connected, and
            // giving up early tears down a pairing that was about to work,
            // so allow longer while the link is up.
            let started = Date()
            var sawConnected = false
            while Date().timeIntervalSince(started) < Self.pairingWait {
                let connected = device.isConnected()
                if connected && device.isPaired() { return .success(()) }
                if connected {
                    sawConnected = true
                } else if sawConnected || Date().timeIntervalSince(started) > Self.connectWait {
                    break   // dropped, or never came up
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            if device.isConnected() {
                // Don't hold on to a link that never finished pairing: it
                // keeps the peripheral from going anywhere else.
                device.closeConnection()
                return .failure(.connectedButNotPaired(mac))
            }
            return .failure(.notConnectedAfterOpen(mac))
        }
    }
}

@objc final class PairDelegate: NSObject, IOBluetoothDevicePairDelegate {
    func devicePairingFinished(_ sender: Any!, error: IOReturn) {}
    func devicePairingPINCodeRequest(_ sender: Any!) {}
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        if let pair = sender as? IOBluetoothDevicePair {
            pair.replyUserConfirmation(true)
        }
    }
    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {}
    func devicePairingStarted(_ sender: Any!) {}
    func devicePairingConnecting(_ sender: Any!) {}
}

extension BluetoothController.PairedDevice.Kind {
    var sortOrder: Int {
        switch self {
        case .keyboard: return 0
        case .mouse: return 1
        case .trackpad: return 2
        case .other: return 3
        }
    }

    var connectOrder: Int {
        switch self {
        case .keyboard: return 0
        case .trackpad: return 1
        case .other: return 2
        case .mouse: return 3
        }
    }

    var symbol: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "hand.point.up.left"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    /// Magic keyboards, mice and trackpads are what BTSwitch is for.
    var isInputDevice: Bool { self != .other }
}
