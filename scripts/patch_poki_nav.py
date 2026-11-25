"""Use guarded paths for app navigation and return search results in one call."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_navigation(bridge_root: Path, core: Path) -> None:
    source = core / "Sources/PokiCore"
    computer = source / "Computer.swift"
    routines = source / "Routines.swift"
    actions = source / "Actions.swift"
    copy2(bridge_root / "ios/PokiAppIntegration/PokiFastActions.swift", source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiNavigationEntry.swift", source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiIconCaption.swift", source)
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiFastActionsTests.swift", tests)

    replace_once(
        computer,
        """        var actions = actions
        var bound: String?""",
        r"""        var actions = actions
        if actions.contains(where: { $0["search_submit"] != nil }) {
            guard actions.count == 1, let spec = actions.first?["search_submit"] else {
                return ToolResult(text: "search_submit must be the only action; nothing was sent", jpeg: nil, isError: true)
            }
            do { actions = try expandSearch(spec) }
            catch { return ToolResult(text: "search_submit: \(error); nothing was sent", jpeg: nil, isError: true) }
        }
        var bound: String?""",
        "PokiCore expand search in the action pipeline",
    )
    replace_once(
        actions,
        """        case .waitUntil:
            return ("wait_until", try await waitUntil(spec, until: until))""",
        """        case .waitUntil:
            if spec["texts_any"] != nil { return ("wait_until", try await waitForResultLabels(spec, until: until)) }
            return ("wait_until", try await waitUntil(spec, until: until))""",
        "PokiCore wait for a search result or empty-state label",
    )
    replace_once(
        computer,
        """            } else if let spec = action["path"], let bundle = (spec["steps"]?.array ?? spec.array)?.first?["launch"].flatMap({ $0.string ?? $0["bundle"]?.string }),""",
        """            } else if let spec = action["path"], let steps = spec["steps"]?.array, steps.count == 1,
                      let app = steps[0]["navigate"]?["app"]?.string,
                      let bundle = config.resolveApp(app) ?? (app.contains(".") && !app.contains(" ") ? app : nil),
                      !config.isPoki(Foreground(bundleID: bundle, name: nil)) {
                front = Foreground(bundleID: bundle, name: nil)
            } else if let spec = action["path"], let bundle = (spec["steps"]?.array ?? spec.array)?.first?["launch"].flatMap({ $0.string ?? $0["bundle"]?.string }),""",
        "PokiCore allow a destination launch from Poki",
    )
    replace_once(
        routines,
        """        let routine = try Self.pathRoutine(spec)
        return try await replay(routine, params: [:], store: nil, until: until)""",
        """        let steps = spec["steps"]?.array ?? []
        if steps.contains(where: { $0["navigate"] != nil }) {
            guard steps.count == 1, let nav = steps.first?["navigate"] else {
                throw ActionFailure(message: "navigate must be the only path step; nothing was sent", delivery: .notSent)
            }
            return try await fastNavigate(nav, until: until)
        }
        let routine = try Self.pathRoutine(spec)
        return try await replay(routine, params: [:], store: nil, until: until)""",
        "PokiCore guard and route destination paths",
    )
    replace_once(
        routines,
        """    func replay(_ skill: Skill, params: [String: String], store: SkillStore?, until: Double) async throws -> String {""",
        """    func replay(_ skill: Skill, params: [String: String], store: SkillStore?, until: Double,
                expectedBundle: String? = nil, initialTarget: String? = nil) async throws -> String {""",
        "PokiCore bind automatic navigation to its app",
    )
    replace_once(
        routines,
        "                    var candidate: String?\n                    let attemptStart = now()",
        """                    // The guarded opening read is the first candidate. A fresh tree must still confirm it.
                    var candidate = index == 0 && closedHere == 0 ? initialTarget : nil
                    let attemptStart = now()""",
        "PokiCore reuse the opening read for navigation stability",
    )
    replace_once(
        routines,
        """                        guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, stepEnds - now() - 0.1)), format: config.treeFormat) else {""",
        """                        guard var tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, stepEnds - now() - 0.1)), format: config.treeFormat) else {""",
        "PokiCore reconcile navigation with the visible page",
    )
    replace_once(
        routines,
        r"""                        if why == "the screen could not be read" { why = "\(target.describe) is not on screen" }""",
        r"""                        if let expectedBundle, tree.foreground.bundleID != expectedBundle {
                            throw stop(index, "the target app is no longer in front")
                        }
                        if expectedBundle != nil, tree.elements.contains(where: { ["Alert", "Sheet"].contains($0.type) && !$0.frame.isEmpty }) {
                            throw stop(index, "a dialog is in front")
                        }
                        if let expectedBundle {
                            let entry = skill.steps.count == 1 && ActionKind(action) == .tap &&
                                step.optional != true && (step.expect?.isEmpty ?? true) && allowed.isEmpty ? target : nil
                            do {
                                let page = try await navigationPage(tree.elements, screen: screen, until: stepEnds,
                                                                    entry: entry, expectedBundle: expectedBundle)
                                if let evidence = page.evidence {
                                    return try await tapVisibleEntry(evidence, app: expectedBundle, screen: screen, until: stepEnds)
                                }
                                tree.elements = page.elements
                            }
                            catch let failure as ActionFailure { throw stop(index, failure.message, failure.delivery) }
                            catch { throw stop(index, "overlapping pages could not be confirmed: \(error)") }
                        }
                        if why == "the screen could not be read" { why = "\(target.describe) is not on screen" }""",
        "PokiCore stop automatic navigation on app or dialog changes",
    )
    patch_launch_pause(computer)


def patch_launch_pause(computer: Path) -> None:
    replace_once(
        computer,
        """        if local, let revision {
            let read = authorizationRead""",
        """        let runnerReady = now()
        if local, let revision {
            let read = authorizationRead""",
        "PokiCore time runner startup",
    )
    replace_once(
        computer,
        """        if let lastKind {
            let pause = min(Self.settle[lastKind] ?? 0.4, max(0, until - now() - config.readTimeout - 0.3))
            if pause >= 0.6, config.quickRead(), let seen = seenBefore {""",
        r"""        let pauseStarted = now()
        if let lastKind {
            let pause = min(Self.settle[lastKind] ?? 0.4, max(0, until - now() - config.readTimeout - 0.3))
            let launchedBundle = toRun.last?["launch"].flatMap { $0.string ?? $0["bundle"]?.string }
            if config.standaloneObservations, lastKind == "launch", let launchedBundle, pause >= 0.6 {
                let (waited, settled) = await launchReadyPause(pause, bundle: launchedBundle)
                did.append(settled ? "read after \(Int((waited * 1000).rounded())) ms: the launched app's controls held still" : "paused \(Int((waited * 1000).rounded())) ms before reading")
            } else if pause >= 0.6, config.quickRead(), let seen = seenBefore {""",
        "PokiCore return a ready launch screen early",
    )
    replace_once(
        computer,
        r"""        let parts = (prepared - callStarted) + actionsTook + readTook + approvalWaited
        lastCallTook = total""",
        r"""        let parts = (prepared - callStarted) + actionsTook + readTook + approvalWaited
        if config.standaloneObservations, actions.contains(where: { $0["launch"] != nil || $0["path"]?["steps"]?.array?.contains(where: { $0["navigate"] != nil }) == true }) {
            let ms: (Double) -> Int = { Int((max(0, $0) * 1000).rounded()) }
            result.text += "\nlaunch_timing: runner=\(ms(runnerReady - callStarted))ms preflight=\(ms(prepared - runnerReady))ms action_preparation=\(ms(actionsStarted - prepared - approvalWaited))ms actions=\(ms(actionsTook))ms settle=\(ms(readStarted - pauseStarted))ms read=\(ms(readTook))ms"
        }
        lastCallTook = total""",
        "PokiCore report startup stages",
    )
