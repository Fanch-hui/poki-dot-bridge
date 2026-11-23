import Foundation
#if canImport(Network)
import Network
#endif

public enum iOSAppLifecycleState: String, Sendable, Equatable {
    case foreground
    case background
    case locked
    case suspended
}

public enum DeviceNetworkKind: String, Sendable, Equatable {
    case unknown
    case wifi
    case cellular
    case offline
}

public struct LifecycleSnapshot: Sendable, Equatable {
    public var lifecycle: iOSAppLifecycleState
    public var network: DeviceNetworkKind
    public var screenLocked: Bool
    public var localDDIMounted: Bool
    public var needsSessionReset: Bool

    public init(
        lifecycle: iOSAppLifecycleState = .foreground,
        network: DeviceNetworkKind = .unknown,
        screenLocked: Bool = false,
        localDDIMounted: Bool = false,
        needsSessionReset: Bool = false
    ) {
        self.lifecycle = lifecycle
        self.network = network
        self.screenLocked = screenLocked
        self.localDDIMounted = localDDIMounted
        self.needsSessionReset = needsSessionReset
    }
}

public protocol NetworkPathMonitoring: Sendable {
    func start(onChange: @escaping @Sendable (DeviceNetworkKind) -> Void)
    func stop()
}

#if canImport(Network)
public final class SystemNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "poki.sites.network.monitor")

    public init() {}

    public func start(onChange: @escaping @Sendable (DeviceNetworkKind) -> Void) {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            let kind: DeviceNetworkKind
            if path.status != .satisfied {
                kind = .offline
            } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                kind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                kind = .cellular
            } else {
                kind = .unknown
            }
            onChange(kind)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
#endif

/// Tracks all 7 iOS runtime states: foreground, background, locked, Wi-Fi<->cellular handover,
/// brief network drops, system suspension, and cold relaunch.
public final class DeviceLifecycleCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = LifecycleSnapshot(needsSessionReset: true)
    private var lastNetworkChangeAt = Date.distantPast
    private var outbox: [ResultRequestDTO] = []
    private let store: CredentialStoring

    public init(store: CredentialStoring) {
        self.store = store
        self.outbox = (try? store.loadOutbox()) ?? []
    }

    public var current: LifecycleSnapshot {
        lock.withLock { snapshot }
    }

    public var pendingOutboxCount: Int {
        lock.withLock { outbox.count }
    }

    public func markForeground() {
        lock.withLock {
            snapshot.lifecycle = snapshot.screenLocked ? .locked : .foreground
        }
    }

    public func markBackground() {
        lock.withLock {
            snapshot.lifecycle = snapshot.screenLocked ? .locked : .background
        }
    }

    public func markSuspended() {
        lock.withLock {
            snapshot.lifecycle = .suspended
        }
    }

    public func markWokeFromSuspension() {
        lock.withLock {
            snapshot.lifecycle = snapshot.screenLocked ? .locked : .foreground
        }
    }

    public func setScreenLocked(_ locked: Bool) {
        lock.withLock {
            snapshot.screenLocked = locked
            if locked {
                snapshot.lifecycle = .locked
            } else if snapshot.lifecycle == .locked {
                snapshot.lifecycle = .foreground
            }
        }
    }

    public func setLocalDDIMounted(_ mounted: Bool) {
        lock.withLock { snapshot.localDDIMounted = mounted }
    }

    /// Returns true if the network type changed cleanly (triggering poll socket reset).
    @discardableResult
    public func updateNetwork(_ kind: DeviceNetworkKind) -> Bool {
        lock.withLock {
            let changed = snapshot.network != kind
            snapshot.network = kind
            if changed { lastNetworkChangeAt = Date() }
            return changed
        }
    }

    public func consumeResetSessionFlag() -> Bool {
        lock.withLock {
            let v = snapshot.needsSessionReset
            snapshot.needsSessionReset = false
            return v
        }
    }

    public func queueOutboxResult(_ result: ResultRequestDTO) {
        lock.withLock {
            outbox.removeAll { $0.task_id == result.task_id }
            outbox.append(result)
            try? store.saveOutbox(outbox)
        }
    }

    public func takeOutboxBatch() -> [ResultRequestDTO] {
        lock.withLock { outbox }
    }

    public func markOutboxDelivered(taskId: String) {
        lock.withLock {
            outbox.removeAll { $0.task_id == taskId }
            try? store.saveOutbox(outbox)
        }
    }

    public func effectivePollDelaySeconds(serverConfig: PollConfigDTO) -> TimeInterval {
        let snap = current
        if snap.network == .offline {
            return 5.0
        }
        if snap.lifecycle == .suspended {
            return 15.0
        }
        if snap.lifecycle == .foreground && serverConfig.mode != "stopped" && serverConfig.mode != "locked" {
            return Double(min(max(50, serverConfig.delay_ms), 2_000)) / 1000.0
        }
        // An unlocked phone remains available for a new Dot task while Poki is in the background.
        if snap.lifecycle == .background && serverConfig.mode == "idle" {
            return Double(min(max(50, serverConfig.delay_ms), 1_000)) / 1000.0
        }
        return Double(max(50, serverConfig.delay_ms)) / 1000.0
    }

    public func effectivePollWaitMs(serverConfig: PollConfigDTO, defaultWaitMs: Int) -> Int {
        let snap = current
        if snap.network == .offline
            || snap.lifecycle == .locked
            || snap.lifecycle == .suspended
            || serverConfig.mode == "stopped"
            || serverConfig.mode == "locked" {
            return 0
        }
        if snap.lifecycle == .background {
            if serverConfig.mode == "idle" && serverConfig.wait_ms == 0 {
                return min(defaultWaitMs, 5_000)
            }
            return min(max(0, serverConfig.wait_ms), 5_000)
        }
        // In foreground, always use a bounded long-poll even if the server starts in "idle" right after pairing.
        return serverConfig.wait_ms > 0 ? min(serverConfig.wait_ms, defaultWaitMs) : defaultWaitMs
    }
}
