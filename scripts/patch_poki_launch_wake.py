"""Bind a cold app launch to its native readiness check and return its timings."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_launch_wake(bridge_root: Path, poki_root: Path) -> None:
    core = poki_root / "native/ios/PokiCore"
    source = core / "Sources/PokiCore"
    computer = source / "Computer.swift"
    integration = bridge_root / "ios/PokiAppIntegration"
    copy2(integration / "PokiLaunchWake.swift", source)
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(integration / "PokiLaunchWakeTests.swift", tests)

    replace_once(
        computer,
        "authorization: AuthorizationWait) async -> RunnerReadiness {\n        var state = host.runnerState()",
        """authorization: AuthorizationWait, launch: PokiLaunchWake? = nil) async -> RunnerReadiness {
        defer { launch?.endWait() }
        var state = PokiLaunchWake.$current.withValue(launch) { host.runnerState() }""",
        "Identify the wake at the point the host is asked to open automation",
    )
    replace_once(
        computer,
        """        switch await waitForRunner(until: started + config.toolDeadline, authorization: local ? .action : .none) {
        case .ready(let deadline, let readyRevision): (until, revision) = (deadline, readyRevision)
        case .blocked(let result): return result""",
        r"""        let launchWake = config.standaloneObservations && !local && !finish && selectedPane == nil
            ? PokiLaunchWake.forLaunch(actions, config: config) : nil
        switch await waitForRunner(until: started + config.toolDeadline, authorization: local ? .action : .none, launch: launchWake) {
        case .ready(let deadline, let readyRevision): (until, revision) = (deadline, readyRevision)
        case .blocked(var result):
            if let timing = launchWake?.timing { result.text += "\n" + timing }
            return result""",
        "Scope cold preparation to a single resolved launch",
    )
    replace_once(
        computer,
        '            result.text += "\\nlaunch_timing: runner=',
        '            if let timing = launchWake?.timing { result.text += "\\n" + timing }\n'
        '            result.text += "\\nlaunch_timing: runner=',
        "Report native session and readability durations with launch timing",
    )
    app = poki_root / "native/ios-app/Poki"
    runtime = app / "Runtime/InProcessWDA.swift"
    replace_once(runtime, "    func prepare() -> [String: Any]",
                 "    func prepare() -> [String: Any]\n    func prepareForAppLaunch() -> [String: Any]",
                 "Launch-specific native preparation")
    model = app / "App/AppModel.swift"
    replace_once(model, "    private var inProcessWarming = false",
                 "    @ObservationIgnored private weak var pendingLaunchWake: PokiLaunchWake?\n"
                 "    private var inProcessWarming = false", "Keep the requesting launch across launcher startup")
    replace_once(model, "        guard sessionOn else { return }\n        if automationPath == .inProcess {\n            if case .closing",
                 """        guard sessionOn else { return }
        if automationPath == .inProcess {
            if let launch = PokiLaunchWake.current, launch.isWaiting { pendingLaunchWake = launch }
            if case .closing""", "Associate the wake with its launch")
    replace_once(model, "        let resuming = sessionKept",
                 """        let resuming = sessionKept
        let launchWake = pendingLaunchWake
        pendingLaunchWake = nil""", "Consume a launch request on one native open")
    replace_once(
        model,
        "            var result = InProcessWDA.openThroughGate { automation.prepare() }",
        """            let prepare = {
                InProcessWDA.openThroughGate {
                    launchWake?.isWaiting == true ? automation.prepareForAppLaunch() : automation.prepare()
                }
            }
            var result = prepare()""", "Keep user authorization in front of both readiness checks")
    replace_once(model, "                result = InProcessWDA.openThroughGate { automation.prepare() }",
                 "                result = prepare()", "Use the same readiness check if native resume fails")
    replace_once(model, "                if token == self.inProcessWarmToken { self.inProcessWarming = false }",
                 """                if token == self.inProcessWarmToken { self.inProcessWarming = false }
                launchWake?.record(sessionSeconds: result["seconds"] as? Double,
                                   proofSeconds: result["warm_seconds"] as? Double,
                                   check: result["readiness_check"] as? String)""", "Attribute accepted native timing to its caller")
    replace_once(model, "first snapshot and screenshot %.2f s", "readability check %.2f s", "Name both readiness paths accurately")
    # Existing test doubles model the ordinary native session.
    app_tests = app.parent / "PokiTests/AppModelTests.swift"
    if app_tests.is_file():
        for name in ("final class FakeAutomation", "private final class DelayedSimulatorAutomation"):
            anchor = name + ": InProcessAutomation, @unchecked Sendable {"
            replace_once(app_tests, anchor, anchor + "\n    func prepareForAppLaunch() -> [String: Any] { prepare() }",
                         "Native session test double")
