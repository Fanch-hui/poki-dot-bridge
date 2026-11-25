"""Bind each guarded action to the app that supplied its observation."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_sequence_guard(bridge_root: Path, poki_root: Path) -> None:
    source = poki_root / "native/ios/PokiCore/Sources/PokiCore"
    computer = source / "Computer.swift"
    core = source / "Core.swift"
    tests = source.parent.parent / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiSequenceGuardTests.swift", tests)
    replace_once(
        computer,
        '        if config.standaloneObservations, let size, !inWorkspace {',
        r'''        if config.standaloneObservations, let bundle = reading.foreground?.bundleID, !inWorkspace {
            header.append("bundle_id: \(bundle)")
        }
        if config.standaloneObservations, let size, !inWorkspace {''',
        "PokiCore report the foreground bundle with the observation",
    )
    replace_once(
        core,
        '"finish": ["type": "boolean"], "app": ["description": "The app to work in',
        '"finish": ["type": "boolean"], "expect_front": ["type": "string"], "app": ["description": "The app to work in',
        "PokiCore accept an exact foreground constraint",
    )
    replace_once(
        core,
        'answerBy: answerBy, app: args["app"], byOwnersVoice: byOwnersVoice, local: local, localTask: localTask)',
        'answerBy: answerBy, app: args["app"], byOwnersVoice: byOwnersVoice, local: local, localTask: localTask, expectFront: args["expect_front"]?.string)',
        "PokiCore pass the foreground constraint to the action runner",
    )
    replace_once(
        computer,
        'localTask: String? = nil) async -> ToolResult {\n        var actions = actions',
        'localTask: String? = nil, expectFront: String? = nil) async -> ToolResult {\n        var actions = actions',
        "PokiCore keep the foreground constraint for the action",
    )
    replace_once(
        computer,
        '            if let app {\n                if app == .bool(false) || app == .null {',
        '''            if expectFront != nil {
                sessionApp = nil
            } else if let app {
                if app == .bool(false) || app == .null {''',
        "PokiCore leave app launching to explicit requests",
    )
    replace_once(
        computer,
        'byOwnersVoice: byOwnersVoice, local: local, localTask: localTask))',
        'byOwnersVoice: byOwnersVoice, local: local, localTask: localTask, expectFront: expectFront))',
        "PokiCore carry the same app into preflight",
    )
    replace_once(
        computer,
        'localTask: String? = nil) async -> ToolResult {\n        scrollFound = nil',
        'localTask: String? = nil, expectFront: String? = nil) async -> ToolResult {\n        scrollFound = nil',
        "PokiCore require an exact foreground app before guarded input",
    )
    replace_once(
        computer,
        '        // The approval card is in Poki: no input lands there',
        '''        if let expectFront {
            let current = try? await runner.raw("GET", "/wda/activeAppInfo",
                                                timeout: 1.5, countsAsMiss: false)
            guard selectedPane == nil, lastForeground?.bundleID == expectFront,
                  current?["bundleId"]?.string == expectFront else {
                return ToolResult(text: "not_sent: the app for this sequence is no longer confirmed in front; nothing was sent",
                                  jpeg: nil, isError: true)
            }
        }

        // The approval card is in Poki: no input lands there''',
        "PokiCore read the actual foreground before guarded input",
    )
    replace_once(
        computer,
        '        let sensitive = firstSensitive(actions)\n        let workspaceSession = workspaceOwner.value',
        r'''        let sensitive = firstSensitive(actions)
        if expectFront != nil, let (index, reason) = sensitive {
            return await readAndReply(until: until, full: full,
                error: "sequence stopped before action \(index + 1): it requires owner approval (\(reason)); nothing was sent in this stage")
        }
        let workspaceSession = workspaceOwner.value''',
        "PokiCore stop the sequence at an approval boundary",
    )
    replace_once(
        computer,
        'numberedFrom: actions.count - toRun.count, moved: movedBefore, approved: approved)',
        'numberedFrom: actions.count - toRun.count, moved: movedBefore, approved: approved, expectFront: expectFront)',
        "PokiCore carry the app through guarded Return",
    )
    replace_once(
        computer,
        'approved: [Int: String] = [:]) async -> (did: [String], error: String?, lastKind: String?)',
        'approved: [Int: String] = [:], expectFront: String? = nil) async -> (did: [String], error: String?, lastKind: String?)',
        "PokiCore allow an exact app to constrain internal stages",
    )
    replace_once(
        computer,
        '            let cap = actionCap(action)\n            let actionsUntil =',
        r'''            if let expectFront, action["key"]?.string == "return" {
                let room = until - now() - config.readTimeout - 0.5
                guard room > 0.3, let query = actions.first?["type"]?.string,
                      let fresh = try? await runner.tree(timeout: min(1.5, room), format: config.treeFormat, countsAsMiss: false),
                      fresh.foreground.bundleID == expectFront, !blockedScreen(fresh.elements),
                      fresh.elements.contains(where: { $0.type == "Keyboard" && !$0.frame.isEmpty }),
                      fresh.elements.filter({ $0.type == "SearchField" && $0.value == query && !$0.frame.isEmpty }).count == 1 else {
                    did.append("key return (not_sent)")
                    error = "the native search field could not be confirmed; Return was not sent"
                    break
                }
            }
            let cap = actionCap(action)
            let actionsUntil =''',
        "PokiCore confirm the app and native search field before Return",
    )
