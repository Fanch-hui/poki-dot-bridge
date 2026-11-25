"""Use the first paired screen read to confirm a single app launch."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_startup(bridge_root: Path, core: Path) -> None:
    source = core / "Sources/PokiCore"
    computer = source / "Computer.swift"
    copy2(bridge_root / "ios/PokiAppIntegration/PokiLaunchRead.swift", source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiLaunchImageEvidence.swift", source)
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiLaunchReadTests.swift", tests)

    replace_once(
        computer,
        "waitForLoadingAfterTap: Bool = false) async -> ToolResult {",
        "waitForLoadingAfterTap: Bool = false, launchedApp: String? = nil) async -> ToolResult {",
        "PokiCore confirm the first post-launch read",
    )
    replace_once(
        computer,
        "        var notes = reading.notes\n        let popup = size.flatMap",
        """        if waitForLoadingAfterTap, !inWorkspace, let size, let previous = lastTree,
           !reading.invalidatesReferences, reading.png != nil,
           let app = reading.foreground?.bundleID, app == lastForeground?.bundleID {
            let confirmation = await confirmTransitionRead(reading, screen: size, app: app,
                                                           previousTree: previous, until: until)
            reading = confirmation.0
            if !confirmation.1 { return unconfirmedTransitionResult(reading, did: did, extra: extra) }
        }
        if let launchedApp, !inWorkspace {
            let confirmation = await confirmLaunchRead(reading, app: launchedApp, until: until)
            reading = confirmation.0
            if !confirmation.1 { return unconfirmedLaunchResult(reading, app: launchedApp, did: did, extra: extra) }
        }
        var notes = reading.notes
        let popup = size.flatMap""",
        "PokiCore confirm launch and post-navigation screenshots",
    )
    replace_once(
        computer,
        """        let pauseStarted = now()
        if let lastKind {""",
        """        let pauseStarted = now()
        let directLaunch = config.standaloneObservations && selectedPane == nil && actions.count == 1 &&
            toRun.count == 1 && error == nil && moreKind == ActionKind.launch.rawValue
            ? toRun.first?["launch"].flatMap { $0.string ?? $0["bundle"]?.string } : nil
        if let lastKind, directLaunch == nil {""",
        "PokiCore read a single launch immediately",
    )
    replace_once(
        computer,
        """                                               moreKind == ActionKind.waitUntil.rawValue))))""",
        """                                               moreKind == ActionKind.waitUntil.rawValue))),
                                        launchedApp: directLaunch)""",
        "PokiCore pass the launched app to the paired read",
    )
    replace_once(
        computer,
        "        while rereads < 6, until - now() > config.readTimeout + 1 {",
        "        while directLaunch == nil, rereads < 6, until - now() > config.readTimeout + 1 {",
        "PokiCore avoid duplicate launch reads after confirmation",
    )
    replace_once(
        computer,
        "        let launched = toRun.compactMap { $0[\"launch\"].flatMap { $0.string ?? $0[\"bundle\"]?.string } }.last",
        """        if directLaunch != nil, lastForeground?.bundleID == "com.apple.springboard", let alert = alertOnScreen() {
            result.text += "\\na system alert is in front after launch (\\(alert)); answer the alert first"
        }
        let launched = toRun.compactMap { $0["launch"].flatMap { $0.string ?? $0["bundle"]?.string } }.last""",
        "PokiCore identify an alert returned after launch",
    )
    replace_once(
        computer,
        "        if let app = cameForward, lastForeground?.bundleID == app, !config.isPoki(lastForeground), app != \"com.apple.springboard\",",
        "        if directLaunch == nil, let app = cameForward, lastForeground?.bundleID == app, !config.isPoki(lastForeground), app != \"com.apple.springboard\",",
        "PokiCore do not relaunch an unconfirmed single launch",
    )
