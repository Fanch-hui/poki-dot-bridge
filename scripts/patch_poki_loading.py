"""Wait briefly for a navigation's loading-only accessibility tree."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_loading(bridge_root: Path, core: Path) -> None:
    source = core / "Sources/PokiCore"
    computer = source / "Computer.swift"
    copy2(bridge_root / "ios/PokiAppIntegration/PokiLoadingScreen.swift", source)
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiLoadingScreenTests.swift", tests)

    replace_once(
        computer,
        "    func readAndReply(until: Double, full: Bool, changes: Bool = false, checkingTouch: Bool = false, did: [String] = [], error: String? = nil, extra: [String] = []) async -> ToolResult {",
        "    func readAndReply(until: Double, full: Bool, changes: Bool = false, checkingTouch: Bool = false, did: [String] = [], error: String? = nil, extra: [String] = [], waitForLoadingAfterTap: Bool = false) async -> ToolResult {",
        "PokiCore loading read option",
    )
    replace_once(
        computer,
        "        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)\n        var notes = reading.notes",
        r'''        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        if waitForLoadingAfterTap, !inWorkspace, let size, let previous = lastTree,
           !reading.invalidatesReferences, reading.png != nil,
           let app = reading.foreground?.bundleID, app == lastForeground?.bundleID,
           PokiLoadingScreen.isPlaceholder(reading.elements, screen: size) {
            let targets = PokiControlTargets(reading.elements, screen: size)
            let tree = listable(reading.elements, size)
                .filter { !targets.visibleFrame($0).isEmpty }
                .map { "\($0.key)@\($0.frame.described)" }.joined(separator: "\n")
            if tree != previous {
                reading = await waitForLoadingScreen(reading, screen: size, app: app, action: "tap", until: until)
                if reading.invalidatesReferences {
                    refs.removeAll()
                    listed.removeAll()
                    lastAll.removeAll()
                    lastTreeAt = nil
                    swipeUnread = true
                }
            }
        }
        var notes = reading.notes''',
        "PokiCore wait for a navigation loading shell",
    )
    replace_once(
        computer,
        "        var result = await readAndReply(until: until, full: full, changes: true, checkingTouch: checkingTouch, did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra)",
        '''        var result = await readAndReply(until: until, full: full, changes: true, checkingTouch: checkingTouch,
                                        did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra,
                                        waitForLoadingAfterTap: config.standaloneObservations &&
                                            toRun.count == actions.count && error == nil &&
                                            steps.isEmpty && approvedNote == nil &&
                                            ((actions.count == 1 && moreKind == ActionKind.tap.rawValue) ||
                                             (actions.contains { $0["type"] != nil } &&
                                              actions.contains { Self.isReturn($0) } &&
                                              (moreKind == ActionKind.key.rawValue ||
                                               moreKind == ActionKind.waitUntil.rawValue))))''',
        "PokiCore wait only after a single successful low-risk tap",
    )
