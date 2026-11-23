import Foundation
import PokiSitesBridge
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Observable MainActor facade binding `SitesBridgeController` inside upstream Poki (`AppModel` + `LiveCore`).
/// Drops into `native/ios-app/Poki/Connect/` once `PokiSitesBridge` is linked in XcodeGen (`project-base.yml`).
@Observable
@MainActor
public final class PokiSitesBridgeSession {
    public private(set) var snapshot: BridgeSnapshot
    public private(set) var isPairing = false
    public private(set) var pairingError: String?

    public var isPaired: Bool {
        snapshot.state != .unpaired && snapshot.state != .revoked
    }

    private let controller: SitesBridgeController
    private var protectedDataObservers: [NSObjectProtocol] = []
    private let onEmergencyStopHook: (@MainActor @Sendable () -> Void)?

    /// Creates a bridge session bound to `LiveCore.handle(_:)` and runner state reader.
    /// Requires the 3-line `func handle(_ request: RelayRequest) async -> RelayResponse` exposure on `LiveCore`.
    public init(
        connectorId: String = "chatgpt-dot-sites",
        runnerStateProvider: @escaping @Sendable () async -> String,
        rpcHandler: @escaping PokiCoreJSONRPCAdapter.SessionRPCHandler,
        onEmergencyStop: (@MainActor @Sendable () -> Void)? = nil,
        onAutomationFinish: (@MainActor @Sendable (String) async -> Bool)? = nil
    ) {
        let adapter = PokiCoreJSONRPCAdapter(
            connectorId: connectorId,
            enableSessionHandshake: true,
            stateReader: runnerStateProvider,
            sessionRPCHandler: rpcHandler
        )
        let config = SitesBridgeConfig(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.0",
            iosVersion: Self.currentIOSVersion()
        )
        let monitor = SystemNetworkPathMonitor()
        let finishHook: (@Sendable () async -> Bool)?
        if let onAutomationFinish {
            finishHook = {
                guard let session = adapter.currentSessionId else { return false }
                return await onAutomationFinish(session)
            }
        } else {
            finishHook = nil
        }
        let ctrl = SitesBridgeController(
            config: config,
            store: KeychainCredentialStore(),
            executor: adapter,
            transport: URLSessionHTTPTransport(configuration: SitesBridgeConfig.makeProxyCompatibleSessionConfiguration()),
            networkMonitor: monitor,
            onAutomationFinish: finishHook
        )
        self.controller = ctrl
        self.snapshot = BridgeSnapshot(
            state: .unpaired,
            deviceId: nil,
            label: nil,
            sessionGeneration: 1,
            activeTaskId: nil,
            lastError: nil,
            pollMode: "warm",
            pendingOutboxCount: 0
        )
        self.onEmergencyStopHook = onEmergencyStop

        Task { [weak self] in
            await ctrl.setOnStateChange { next in
                Task { @MainActor [weak self] in
                    self?.snapshot = next
                }
            }
            let initial = await ctrl.snapshot()
            await MainActor.run {
                self?.snapshot = initial
            }
        }
        installProtectedDataObservers()
    }

    public func pair(
        sitesURL: String,
        pairingCode: String,
        deviceName: String?,
        siwcBypassToken: String?
    ) async {
        isPairing = true
        pairingError = nil
        defer { isPairing = false }
        do {
            _ = try await controller.pair(
                sitesURL: sitesURL,
                pairingCode: pairingCode,
                deviceName: deviceName,
                siwcBypassToken: siwcBypassToken
            )
            snapshot = await controller.snapshot()
        } catch {
            pairingError = error.localizedDescription
            snapshot = await controller.snapshot()
        }
    }

    public func updateSIWCBypassToken(_ token: String) async {
        pairingError = nil
        do {
            try await controller.updateSIWCBypassToken(token)
            snapshot = await controller.snapshot()
        } catch {
            pairingError = error.localizedDescription
        }
    }

    public func start() {
        Task {
            await controller.start()
            snapshot = await controller.snapshot()
        }
    }

    public func stop() {
        Task {
            await controller.stop()
            snapshot = await controller.snapshot()
        }
    }

    public func unpair() {
        Task {
            await controller.unpair()
            snapshot = await controller.snapshot()
        }
    }

    public func triggerEmergencyStop() {
        onEmergencyStopHook?()
        Task {
            await controller.triggerOwnerEmergencyStop(reason: "Stopped from Poki iPhone UI")
            snapshot = await controller.snapshot()
        }
    }

    public func handleScenePhase(_ phase: ScenePhase, automationEnabled: Bool) {
        Task {
            switch phase {
            case .active:
                await controller.updateLifecycle(foreground: true)
                if automationEnabled { await controller.markWokeFromSuspension() }
            case .background:
                await controller.updateLifecycle(foreground: false)
            case .inactive:
                break
            @unknown default:
                break
            }
            snapshot = await controller.snapshot()
        }
    }

    public func setDDIMounted(_ mounted: Bool) {
        Task {
            await controller.setLocalDDIMounted(mounted)
        }
    }

    public func reportApprovalRequested(
        id: String,
        app: String?,
        summary: String,
        reason: String,
        expiresAt: Date?
    ) {
        let dto = PendingApprovalDTO(
            id: id,
            app: app,
            summary: summary,
            reason: reason,
            expires_at: expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
        Task {
            await controller.reportPendingApproval(dto)
        }
    }

    public func reportApprovalEnded() {
        Task {
            await controller.reportPendingApproval(nil)
        }
    }

    public func canApplyOwnerApproval(id: String) async -> Bool {
        await controller.canApplyOwnerApproval(id: id)
    }

    public func reportHandoffRequested(id: String, kind: String, text: String?, app: String?) {
        let allowedKinds: Set<String> = ["passcode", "password", "verification", "payment", "other"]
        let safeKind = allowedKinds.contains(kind) ? kind : "other"
        let dto = PendingHandoffDTO(
            id: id,
            kind: safeKind,
            text: text ?? "Owner action required",
            app: app,
            requested_at: Int64(Date().timeIntervalSince1970 * 1000)
        )
        Task {
            await controller.reportPendingHandoff(dto)
        }
    }

    public func reportHandoffEnded() {
        Task {
            await controller.reportPendingHandoff(nil)
        }
    }

    private func installProtectedDataObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let lockObs = center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.controller.setScreenLocked(true)
            }
        }
        let unlockObs = center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.controller.setScreenLocked(false)
            }
        }
        protectedDataObservers = [lockObs, unlockObs]
        #endif
    }

    private static func currentIOSVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return "27.3"
        #endif
    }
}
