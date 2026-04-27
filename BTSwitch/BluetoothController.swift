import Foundation
import IOBluetooth

/// Wraps the IOBluetooth primitives we need.
///
/// All work is funneled through a dedicated background queue. This is critical
/// for IOBluetoothDevicePair.start() — its delegate callbacks are delivered on
/// the queue from which start() was invoked, and openConnection() blocks that
/// queue until the radio handshake completes. Doing this on the main thread
/// of a CLI deadlocks; doing it inside an app's main thread also blocks the UI.
/// The dedicated queue keeps both problems away.
///
/// Public methods are synchronous from the caller's perspective but always run
/// on the internal queue. Callers should NEVER call these from the main thread
/// without dispatching, since some of them block for seconds.
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

    private static let invalidRSSI: Int8 = 127
    private let queue = DispatchQueue(label: "com.user.btswitch.bluetooth", qos: .userInitiated)

    // MARK: - Read-only state (cheap, can be called from any thread)

    var isPoweredOn: Bool {
        guard let host = IOBluetoothHostController.default() else { return false }
        return host.powerState != kBluetoothHCIPowerStateOFF
    }

    func isConnected(_ mac: String) -> Bool {
        guard let dev = IOBluetoothDevice(addressString: mac) else { return false }
        return dev.isConnected()
    }

    func rssi(_ mac: String) -> Int8? {
        guard let dev = IOBluetoothDevice(addressString: mac) else { return nil }
        let r = dev.rssi()
        return r == Self.invalidRSSI ? nil : r
    }

    // MARK: - Mutating ops (run on the dedicated queue)

    /// Pair-and-connect. Synchronous. Caller must NOT be on the main thread.
    func connect(_ mac: String) -> Result<Void, ConnectError> {
        return queue.sync { self.doConnect(mac) }
    }

    /// Soft disconnect. Synchronous.
    func disconnect(_ mac: String) -> Bool {
        return queue.sync {
            guard let device = IOBluetoothDevice(addressString: mac) else { return false }
            if !device.isConnected() { return true }
            return device.closeConnection() == kIOReturnSuccess
        }
    }

    /// Hard unregister via private "remove" selector. Synchronous.
    @discardableResult
    func remove(_ mac: String) -> Bool {
        return queue.sync {
            guard let device = IOBluetoothDevice(addressString: mac) else { return false }
            let sel = NSSelectorFromString("remove")
            guard device.responds(to: sel) else { return false }
            _ = device.perform(sel)
            return true
        }
    }

    // MARK: - Internal

    private func doConnect(_ mac: String) -> Result<Void, ConnectError> {
        guard isPoweredOn else { return .failure(.bluetoothOff) }
        guard let device = IOBluetoothDevice(addressString: mac) else {
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

        let pairRC = devicePair.start()
        if pairRC != kIOReturnSuccess {
            return .failure(.pairStartFailed(mac, pairRC))
        }

        // openConnection blocks while the radio handshake completes.
        let openRC = device.openConnection()

        withExtendedLifetime(delegate) { }
        withExtendedLifetime(devicePair) { }

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
