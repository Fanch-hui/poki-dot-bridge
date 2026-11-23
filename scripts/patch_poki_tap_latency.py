"""Read an immediately ready screen after a single ordinary tap."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_tap_latency(bridge_root: Path, core: Path) -> None:
    source = core / "Sources/PokiCore"
    computer = source / "Computer.swift"
    copy2(bridge_root / "ios/PokiAppIntegration/PokiTapLatency.swift", source)
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiTapLatencyTests.swift", tests)

    replace_once(
        computer,
        "waitForLoadingAfterTap: Bool = false, launchedApp: String? = nil) async -> ToolResult {",
        "waitForLoadingAfterTap: Bool = false, launchedApp: String? = nil, tapFinishedAt: Double? = nil, tapTarget: Element? = nil) async -> ToolResult {",
        "PokiCore single-tap read option",
    )
    replace_once(
        computer,
        "        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)\n        if waitForLoadingAfterTap",
        """        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        if let tapFinishedAt, let tapTarget, !inWorkspace {
            reading = await confirmTapRead(reading, screen: screen, target: tapTarget,
                                           tapFinishedAt: tapFinishedAt, until: until)
            if reading.invalidatesReferences {
                refs.removeAll()
                listed.removeAll()
                lastAll.removeAll()
                lastTreeAt = nil
                swipeUnread = true
            }
        }
        if waitForLoadingAfterTap""",
        "PokiCore confirm an immediately returned tap read",
    )
    replace_once(
        computer,
        """        if let lastKind, directLaunch == nil {""",
        """        let tapTarget = toRun.first.flatMap { navigationTapTarget($0) }
        let directTap = config.standaloneObservations && selectedPane == nil && actions.count == 1 &&
            toRun.count == 1 && error == nil && steps.isEmpty && approvedNote == nil &&
            moreKind == ActionKind.tap.rawValue && lastTree != nil && lastPicture?.cells.isEmpty == false &&
            lastForeground?.bundleID != nil && size != nil && tapTarget != nil
        if let lastKind, directLaunch == nil, !directTap {""",
        "PokiCore start the tap read immediately",
    )
    replace_once(
        computer,
        "                                        launchedApp: directLaunch)",
        "                                        launchedApp: directLaunch, tapFinishedAt: directTap ? pauseStarted : nil,\n                                        tapTarget: directTap ? tapTarget : nil)",
        "PokiCore pass the tap time into its read",
    )
