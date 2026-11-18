import AppKit
import IOKit.pwr_mgt

/// Tracks whether this Mac is properly awake, and can wake it up or keep it
/// awake while peripherals move.
///
/// A sleeping Mac can be woken briefly by network traffic ("dark wake",
/// via Wake for network access or a Bonjour sleep proxy). It then answers on
/// the network with the screen off and drops back to sleep seconds later,
/// often in the middle of pairing. macOS posts `didWakeNotification` only
/// on a full wake, so between `willSleep` and `didWake` we treat the Mac as
/// asleep even if it's answering requests.
///
/// Thread-safe.
final class PowerMonitor {
    private let logger: AppLogger
    private let lock = NSLock()
    private var awake = true
    private var epoch = 0
    private var activityID: IOPMAssertionID = 0
    private var observers: [NSObjectProtocol] = []

    init(logger: AppLogger) {
        self.logger = logger
    }

    /// Call once on main.
    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.lock.locked {
                self.awake = false
                self.epoch += 1
            }
            self.logger.info("this Mac is going to sleep")
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.lock.locked { self.awake = true }
            self.logger.info("this Mac woke up")
        })
    }

    /// False from the moment macOS announces sleep until it fully wakes,
    /// including any dark wake in between.
    var isAwake: Bool { lock.locked { awake } }

    /// Changes every time the Mac starts going to sleep. Work that spans a
    /// change was interrupted by sleep and is stale.
    var sleepEpoch: Int { lock.locked { epoch } }

    /// Acts as if someone touched the keyboard: turns the display on,
    /// promotes a dark wake to a full wake, and postpones idle sleep.
    func declareUserActivity(_ reason: String) {
        lock.locked {
            var id = activityID
            let rc = IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id)
            if rc == kIOReturnSuccess { activityID = id }
        }
    }

    /// Blocks until fully awake or `timeout` passes. Not on main.
    func waitUntilAwake(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isAwake {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    /// Keeps the Mac from idle-sleeping until the returned closure is
    /// called. The closure is safe to call more than once.
    func preventSleep(_ reason: String) -> () -> Void {
        var id: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             reason as CFString, &id)
        guard rc == kIOReturnSuccess else {
            logger.warn("couldn't stop this Mac sleeping: 0x\(String(rc, radix: 16))")
            return {}
        }
        let released = NSLock()
        var done = false
        return {
            released.locked {
                guard !done else { return }
                done = true
                IOPMAssertionRelease(id)
            }
        }
    }
}

private extension NSLock {
    /// Like `withLock`, which needs macOS 14.
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
