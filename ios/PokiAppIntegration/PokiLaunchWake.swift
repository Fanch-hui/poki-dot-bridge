import Foundation

/// One launch owns its readiness measurements, including when the launcher wakes asynchronously.
public final class PokiLaunchWake: Sendable {
    @TaskLocal public static var current: PokiLaunchWake?

    private let waiting = LockedBox(true)
    private let measurements = LockedBox<String?>(nil)
    public var isWaiting: Bool { waiting.value }
    var timing: String? { measurements.value }

    static func forLaunch(_ actions: [JSON], config: CoreConfig) -> PokiLaunchWake? {
        guard actions.count == 1, let action = actions.first else { return nil }
        let app: String?
        switch ActionKind(action) {
        case .launch:
            let spec = action["launch"]
            app = spec?.string ?? spec?["bundle"]?.string
        case .path:
            guard let steps = action["path"]?["steps"]?.array, steps.count == 1,
                  let target = steps[0]["navigate"]?["app"]?.string else { return nil }
            app = config.resolveApp(target) ?? target
        default:
            return nil
        }
        guard let app, app.contains("."), !app.contains(" ") else { return nil }
        return PokiLaunchWake()
    }

    func endWait() { waiting.value = false }

    public func record(sessionSeconds: Double?, proofSeconds: Double?, check: String?) {
        var parts: [String] = []
        if let sessionSeconds { parts.append("session_open=\(Int((sessionSeconds * 1000).rounded()))ms") }
        if let proofSeconds { parts.append("readability=\(Int((proofSeconds * 1000).rounded()))ms") }
        if let check { parts.append("proof=\(check)") }
        if !parts.isEmpty { measurements.value = "launch_timing: " + parts.joined(separator: " ") }
    }
}
