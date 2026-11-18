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

        var description: String {
            switch self {
            case .bluetoothOff: return "Bluetooth is off"
            case .deviceNotFound(let m): return "device not found: \(m)"
            case .invalidRSSI(let m): return "\(m) asleep or out of range; press a key / click to wake it"
            case .pairInitFailed(let m): return "could not initialise pairing for \(m)"
            case .pairStartFailed(let m, let rc): return "pair start failed for \(m): 0x\(String(rc, radix: 16))"
            case .openConnectionFailed(let m, let rc): return "openConnection failed for \(m): 0x\(String(rc, radix: 16))"
            case .notConnectedAfterOpen(let m): return "openConnection ok but \(m) not reporting connected"
            }
        }
    }

    enum RemoveResult: Equatable, CustomStringConvertible {
        case removed
        case notPaired          // nothing to do
        case stillPaired        // `remove` ran but the device is still paired
        case unsupported        // private selector missing (macOS changed)
        case deviceNotFound

        var description: String {
            switch self {
            case .removed: return "removed"
            case .notPaired: return "not paired (no-op)"
            case .stillPaired: return "remove had no effect; device still paired"
            case .unsupported: return "remove API unavailable on this macOS version"
            case .deviceNotFound: return "device not found"
            }
        }

        var isFailure: Bool { self == .stillPaired || self == .unsupported }
    }

    private static let invalidRSSI: Int8 = 127
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).bluetooth", qos: .userInitiated)

    // MARK: - Reads

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
            if !device.isPaired() { return .notPaired }
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

            // isConnected can lag a bit. Poll briefly.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if device.isConnected() { return .success(()) }
                Thread.sleep(forTimeInterval: 0.2)
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
