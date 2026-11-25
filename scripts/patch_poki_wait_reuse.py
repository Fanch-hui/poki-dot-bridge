"""Reuse a paired read when the last wait confirms an unambiguous page."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_wait_reuse(bridge_root: Path, core: Path) -> None:
    source = core / "Sources/PokiCore"
    computer = source / "Computer.swift"
    actions = source / "Actions.swift"
    fast = source / "PokiFastActions.swift"
    copy2(bridge_root / "ios/PokiAppIntegration/PokiWaitReuse.swift", source)
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiWaitReuseTests.swift", tests)

    replace_once(
        computer,
        "    var runEndedOnARead = false",
        "    var runEndedOnARead = false\n    let waitReuse = LockedBox<PokiWaitReuse?>(nil)",
        "PokiCore keep paired wait read scoped to an action",
    )
    replace_once(
        computer,
        "tapTarget: Element? = nil) async -> ToolResult {",
        "tapTarget: Element? = nil, waitReading: Reading? = nil) async -> ToolResult {",
        "PokiCore allow the final wait's paired read",
    )
    replace_once(
        computer,
        """        var reading = await runner.read(timeout: budget, extra: max(0, min(4, until - now() - budget - 3)), format: config.treeFormat,
                                        callEnds: until, allowHostPicture: !inWorkspace, workspace: inWorkspace)""",
        """        var reading: Reading
        if let waitReading {
            reading = waitReading
        } else {
            reading = await runner.read(timeout: budget, extra: max(0, min(4, until - now() - budget - 3)), format: config.treeFormat,
                                        callEnds: until, allowHostPicture: !inWorkspace, workspace: inWorkspace)
        }""",
        "PokiCore reuse the final wait read in the normal reply pipeline",
    )
    replace_once(
        computer,
        """        let actionsStarted = now()
        let approved = approvedNote == nil ? [:] : Dictionary(steps.map { ($0.at, $0.reason) }, uniquingKeysWith: { a, _ in a })""",
        """        let actionsStarted = now()
        let reusableWait = prepareWaitReuse(toRun, allowed: config.standaloneObservations && selectedPane == nil &&
                                            toRun.count == actions.count && steps.isEmpty && approvedNote == nil)
        waitReuse.value = reusableWait
        defer { waitReuse.value = nil }
        let approved = approvedNote == nil ? [:] : Dictionary(steps.map { ($0.at, $0.reason) }, uniquingKeysWith: { a, _ in a })""",
        "PokiCore scope wait reuse to a low-risk action",
    )
    replace_once(
        computer,
        "                                        tapTarget: directTap ? tapTarget : nil)",
        "                                        tapTarget: directTap ? tapTarget : nil,\n                                        waitReading: error == nil ? waitReuse.value?.reading : nil)",
        "PokiCore consume the confirmed wait read",
    )
    replace_once(
        actions,
        """            if let seen = try? await runner.tree(timeout: Swift.min(config.readTimeout, room), format: config.treeFormat) {
                reads += 1""",
        """            if let seen = await waitScreen(timeout: Swift.min(config.readTimeout, room), until: until) {
                reads += 1""",
        "PokiCore pair the first wait read with its picture",
    )
    replace_once(
        actions,
        '                    if present != gone { return "wait_until: \\(what) after \\(ms) ms" }',
        '''                    if present != gone {
                        if !gone { await saveWaitReading(seen, label: text, until: until, allowField: true) }
                        return "wait_until: \\(what) after \\(ms) ms"
                    }''',
        "PokiCore retain a matching final wait read",
    )
    replace_once(
        fast,
        """            if let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, limit - now())), format: config.treeFormat, countsAsMiss: false) {
                guard expectedApp == nil || tree.foreground.bundleID == expectedApp else {""",
        """            if let tree = await waitScreen(timeout: min(config.readTimeout, max(0.3, limit - now())),
                                           until: until, countsAsMiss: false) {
                guard expectedApp == nil || tree.foreground.bundleID == expectedApp else {""",
        "PokiCore pair the first search wait read with its picture",
    )
    replace_once(
        fast,
        '                    return "wait_until: result \\"\\(label)\\" appeared after \\(Int(((now() - started) * 1000).rounded())) ms"',
        '''                    await saveWaitReading(tree, label: label, until: until)
                    return "wait_until: result \\"\\(label)\\" appeared after \\(Int(((now() - started) * 1000).rounded())) ms"''',
        "PokiCore retain a matching search result read",
    )
