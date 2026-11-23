"""Install the Dot-only app shell and its Live Activity into the pinned Poki build."""

import json
from pathlib import Path
from shutil import copy2


def replace_once(path: Path, old: str, new: str, label: str = "Live Activity") -> None:
    text = path.read_text(encoding="utf-8")
    if new in text and (new not in old or old not in text):
        return
    if old not in text:
        raise RuntimeError(f"[{label}] Expected anchor not found in {path}:\n{old}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def patch_dot_app(bridge_root: Path, poki_root: Path) -> None:
    app = poki_root / "native/ios-app/Poki"
    copy2(bridge_root / "ios/PokiAppIntegration/DotBridgeApp.swift", app / "App/PokiApp.swift")
    replace_once(
        app / "Chat/PokiDetailsView.swift",
        "private struct LanguageSettingsView: View {",
        "struct LanguageSettingsView: View {",
        "Dot Bridge language settings",
    )
    app_model = app / "App/AppModel.swift"
    patch_owner_approval(app_model)
    replace_once(
        app_model,
        """    func handoffTick() {
        if let what = PokiHandoff.takeSealedKey() {
            log.add("setup", what)
            turnOnIfWanted()
        }
        PokiHandoff.writeHello""",
        "    func handoffTick() {\n        PokiHandoff.writeHello",
        "Dot Bridge installer status",
    )
    replace_once(
        app_model,
        """    /// The outside agent driving the phone now: its MCP session's client, or the agent that handed
    /// a task to Poki. nil while Poki's own chat drives it.
    var currentCaller: String? {
        let store = SessionStore.shared
        if let id = store.activeSessionID, let client = store.session(id)?.client { return client }
        return ChatModel.delegatedBusy
    }""",
        '    var currentCaller: String? { "Dot" }',
        "Dot Bridge caller",
    )
    replace_once(
        app_model,
        """        // An agent whose session began before this launch is named from its connector.
        SessionStore.shared.connectorAgent = { [identity] hash in
            identity.secrets.first { $0.hash == hash }.map { $0.named ? $0.name : ($0.agent ?? $0.name) }
        }
        if UserDefaults.standard.string(forKey: "pokiSample") != nil { loadSample() }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification""",
        '        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification',
        "Dot Bridge startup data",
    )
    replace_once(
        app_model,
        """        // Every outside agent's session and step goes into the Sessions list, on or off.
        SessionStore.shared.observe(event, approvals: approvals)
        // The first agent through a connector names it (unless the owner did) and gives it its icon.
        if case .session(.started(_, let client, _, let connector?)) = event {
            identity.noteAgent(hash: connector, client: AgentName.pretty(client))
        }
        // Events after Turn off (the core's own "stopped") are not for the screen.""",
        '        // Events after Turn off (the core\'s own "stopped") are not for the screen.',
        "Dot Bridge session recording",
    )
    replace_once(
        app_model,
        """            // A step of an outside agent's own session (not the chat's): the owner is told when it is through.
            if let session, let client = SessionStore.shared.outsideClient(ofMCPSession: session) { outsideAgentsAtWork[session] = client }""",
        '            if let session { outsideAgentsAtWork[session] = "Dot" }',
        "Dot Bridge in-flight activity",
    )
    replace_once(
        app_model,
        r"""            activityText = summary
            log.add("agent", "started: \(summary)")""",
        "            activityText = summary",
        "Dot Bridge action start logging",
    )
    replace_once(
        app_model,
        r"""            let failed = delivery.hasPrefix("failed")
            log.add("agent", "\(failed ? "failed" : "done"): \(summary) · \(delivery.prefix(160))" + (error.map { " · \($0)" } ?? ""))""",
        '            let failed = delivery.hasPrefix("failed")',
        "Dot Bridge action result logging",
    )
    replace_once(
        app_model,
        "        case .toolFinished(let summary, let delivery, let app, let thumbnail, let error, _):",
        "        case .toolFinished(let summary, let delivery, let app, let thumbnail, _, _):",
        "Dot Bridge tool result event",
    )
    replace_once(
        app_model,
        """            // The owner's own record of every action, with the run it came from.
            let chat = AskPoki.chat
            ActionLog.shared.add(summary, app: app, ok: !failed,
                                 session: SessionStore.shared.activeSessionID ?? (chat?.running == true ? chat?.sessionID : nil),
                                 caller: currentCaller)
            if recentSteps.count > 20""",
        "            if recentSteps.count > 20",
        "Dot Bridge action recording",
    )
    replace_once(
        app_model,
        """            sitesBridge.reportApprovalEnded()
            if let approval = approvals.first(where: { $0.id == id }) {
                record(approval, approved: approved)
            } else if let approval = checking.first(where: { $0.id == id }) {
                record(approval, approved: approved)
            }
            approvals.removeAll { $0.id == id }""",
        """            sitesBridge.reportApprovalEnded()
            approvals.removeAll { $0.id == id }""",
        "Dot Bridge approval recording",
    )
    replace_once(
        app_model,
        r"""    /// Approvals from the app's own screen (the same path as the Live Activity's buttons).
    /// An approval's answer in the Activity Log: what was asked, who answered, and the model's reason.
    private func record(_ approval: PendingApproval, approved: Bool?) {
        let detail: String
        if ApprovalClassifier.modelAnswered(approval.id), let verdict = ApprovalClassifier.verdicts[approval.id] {
            detail = (approved == true ? AppLocalization.text(LocalizedStringResource("Allowed automatically")) : AppLocalization.text(LocalizedStringResource("Not allowed automatically"))) + (verdict.reason.isEmpty ? "" : ": \(verdict.reason)")
        } else if ApprovalClassifier.mode == .off, !ApprovalClassifier.requiresOwner(approval) {
            detail = AppLocalization.text(LocalizedStringResource("Allowed, asking is off"))

        } else {
            switch approved {
            case true?: detail = AppLocalization.text(LocalizedStringResource("You allowed it"))
            case false?: detail = AppLocalization.text(LocalizedStringResource("You did not allow it"))
            case nil: detail = AppLocalization.text(LocalizedStringResource("Ran out before an answer"))
            }
        }
        let chat = AskPoki.chat
        ActionLog.shared.add(approval.summary, app: approval.app, ok: approved == true,
                             session: SessionStore.shared.activeSessionID ?? (chat?.running == true ? chat?.sessionID : nil),
                             caller: currentCaller, kind: .approval, detail: detail, why: approval.reason)
    }

    /// Each request is answered by the owner on the Live Activity, or on a notification when there is none.""",
        "    /// Each request is answered by the owner on the Live Activity, or on a notification when there is none.",
        "Dot Bridge approval log storage",
    )
    replace_once(
        poki_root / "native/ios-app/PokiWidgets/PokiWidgetsBundle.swift",
        "        PokiLiveActivity()\n        TalkToPokiControl()",
        "        PokiLiveActivity()",
        "Dot Bridge widget controls",
    )


def patch_dot_island(bridge_root: Path, poki_root: Path) -> None:
    shared = poki_root / "native/ios-app/Shared"
    for filename in ("DotIslandViews.swift", "DotLiveActivityViews.swift"):
        copy2(bridge_root / "ios/PokiAppIntegration" / filename, shared)
    patch_dot_branding(bridge_root, poki_root)

    translations = json.loads(
        (bridge_root / "ios/PokiAppIntegration/DotBridgeLocalizations.json").read_text(encoding="utf-8")
    )
    patch_string_catalog(shared / "LiveActivity.xcstrings", translations["liveActivity"])
    patch_string_catalog(shared / "Localizable.xcstrings", translations["localizable"])
    patch_app_localization(shared / "AppLocalization.swift")

    replace_once(
        shared / "ActivityFace.swift",
        """        var face = baseFace
        face.caller = caller""",
        """        var face = baseFace
        if phase == .approval, approval != nil {
            face.kicker = String(activity: "Needs your confirmation")
        }
        face.caller = caller""",
        "Dot Bridge approval status",
    )

    widget = poki_root / "native/ios-app/PokiWidgets/PokiWidgetsBundle.swift"
    replace_once(
        widget,
        """        ActivityConfiguration(for: PokiActivityAttributes.self) { context in
            let face = context.face
            LockScreenCard(face: face).dynamicTypeSize(...ActivityMetrics.largestType)
                .environment(\\.colorScheme, .dark)
                .environment(\\.locale, AppLocalization.locale)
                // Outside the line above, where the system's own appearance can still be read: the flat
                // colour that goes with the card's gradient, and light or dark handed down to the card.
                .modifier(CardTint())
                .activitySystemActionForegroundColor(.white)
                .widgetURL(face.link)
        } dynamicIsland: { context in
            let face = context.face
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { IslandLeading(face: face).dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale).modifier(TapShield(on: face.shieldsTaps)) }
                DynamicIslandExpandedRegion(.trailing) { IslandTrailing(face: face).dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale).modifier(TapShield(on: face.shieldsTaps)) }
                DynamicIslandExpandedRegion(.bottom) { IslandBottom(face: face).dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale).modifier(TapShield(on: face.shieldsTaps)) }
            } compactLeading: {
                CompactLeading(face: face).dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale)
            } compactTrailing: {
                CompactTrailing(face: face).dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale)
            } minimal: {
                MinimalView(face: face).dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale)
            }
            .widgetURL(face.link)
            // Always Poki's blue; the system draws the outline only over a dark background, at its own width.
            .keylineTint(ActivityTheme.current.outline)
            // No margins: the bear stands on the island's own edge, and the views keep their distances.
            .contentMargins(.all, 0, for: .expanded)
            .contentMargins(.all, 0, for: .compactLeading)
            .contentMargins(.all, 0, for: .minimal)
        }""",
        """        ActivityConfiguration(for: PokiActivityAttributes.self) { context in
            let _ = AppLocalization.setWidgetLanguage(context.state.uiLanguage)
            let face = context.face
            DotLockScreenCard(face: face)
                .dynamicTypeSize(...ActivityMetrics.largestType)
                .environment(\\.locale, AppLocalization.locale)
                .widgetURL(face.link)
        } dynamicIsland: { context in
            AppLocalization.setWidgetLanguage(context.state.uiLanguage)
            let face = context.face
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { DotIslandExpandedLeading().dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale).modifier(TapShield(on: face.shieldsTaps)) }
                DynamicIslandExpandedRegion(.trailing) { DotIslandExpandedTrailing().dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale).modifier(TapShield(on: face.shieldsTaps)) }
                DynamicIslandExpandedRegion(.bottom) { DotIslandExpandedBottom(face: face).dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale).modifier(TapShield(on: face.shieldsTaps)) }
            } compactLeading: {
                DotIslandLeading().dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale)
            } compactTrailing: {
                DotIslandTrailing(state: context.state, face: face, isStale: context.isStale).dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale)
            } minimal: {
                DotIslandMinimal().dynamicTypeSize(...ActivityMetrics.largestType).environment(\\.locale, AppLocalization.locale)
            }
            .widgetURL(face.link)
            .keylineTint(Color.white.opacity(0.22))
            .contentMargins(.all, 0, for: .expanded)
            .contentMargins(.all, 0, for: .compactLeading)
            .contentMargins(.all, 0, for: .minimal)
        }""",
        "Dot Bridge Live Activity widgets",
    )

    controller = poki_root / "native/ios-app/Poki/Activity/ActivityController.swift"
    replace_once(
        controller,
        """    private func content() -> ActivityContent<PokiState> {
        trimToFit()""",
        """    private func content() -> ActivityContent<PokiState> {
        state.uiLanguage = AppLocalization.language
        trimToFit()""",
        "Dot Bridge activity language propagation",
    )
    replace_once(
        controller,
        """        let summary = state.doneLine ?? state.runTime ?? ""
        let popUp = alert ? ordinary(StatusWord.done.text, summary) : nil
        send(alert: popUp, critical: true)
        armFold()
        return popUp != nil && isRunning && Self.hasDynamicIsland()""",
        """        send(alert: nil, critical: true)
        armFold()
        return false""",
    )
    app_model = poki_root / "native/ios-app/Poki/App/AppModel.swift"
    replace_once(
        app_model,
        """        // One surface per approval. With a Live Activity, its alert is the ask (Allow and Don't Allow
        // on the expanded island and the Lock Screen card): a banner on top of it put two asks over the
        // top of the screen, and a tap on the banner opens Poki in the middle of the task. The
        // time-sensitive notification is for when there is no Live Activity to pop up: off in
        // Settings, dismissed, or Poki turned on from the background, where iOS starts none.
        if activity.isRunning {
            log.add("approval", "asked on the Live Activity only, no notification")
        } else {
            ApprovalNotice.post(approval, caller: caller)
        }""",
        """        ApprovalNotice.post(approval, caller: caller)""",
        "Dot Bridge approval notification",
    )
    replace_once(
        poki_root / "native/ios-app/Poki/Activity/ApprovalNotice.swift",
        """        content.title = approval.question
        content.categoryIdentifier""",
        """        content.title = String(activity: "Dot needs your confirmation")
        content.body = approval.question
        content.categoryIdentifier""",
        "Dot Bridge approval notification text",
    )


def patch_dot_branding(bridge_root: Path, poki_root: Path) -> None:
    ios = poki_root / "native/ios-app"
    copy2(bridge_root / "ios/PokiAppIntegration/RenderDotAppIcon.swift", ios / "scripts")
    replace_once(
        ios / "scripts/make-assets.sh",
        'ICON="$ROOT/docs/images/poki-app-icon.png"',
        'ICON="$HERE/scripts/DotAppIcon.png"\nswift "$HERE/scripts/RenderDotAppIcon.swift" "$ICON"',
        "Dot Bridge app icon",
    )


def patch_app_localization(path: Path) -> None:
    replace_once(
        path,
        """    private static var resolved: LocalizationCache.Value {
        #if POKI_APP
        let preference = shared.preference // Keep SwiftUI's Observation dependency.
        #else
        // Re-read this cheap key: defaults notifications do not reliably cross process boundaries.
        let preference = SharedContainer.defaults.string(forKey: "effectiveUILanguage") ?? system
        #endif
        return cache.value(for: preference)
    }""",
        """    private static let overrideLock = NSLock()
    private static var widgetOverride: String?

    static func setWidgetLanguage(_ language: String?) {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        if let language, !language.isEmpty {
            widgetOverride = language
        } else {
            widgetOverride = nil
        }
    }

    private static var resolved: LocalizationCache.Value {
        #if POKI_APP
        let preference = shared.preference // Keep SwiftUI's Observation dependency.
        #else
        overrideLock.lock()
        let override = widgetOverride
        overrideLock.unlock()
        // Re-read this cheap key: defaults notifications do not reliably cross process boundaries.
        let preference = override ?? SharedContainer.defaults.string(forKey: "effectiveUILanguage") ?? system
        #endif
        return cache.value(for: preference)
    }""",
        "Dot Bridge widget language override",
    )


def patch_owner_approval(app_model: Path) -> None:
    replace_once(
        app_model,
        """    func resolve(_ approval: PendingApproval, approved: Bool) {
        core.resolveApproval(id: approval.id, approved: approved)
    }

    /// Don’t Ask Again on an approval's card: this step goes through and approvals are off from now on.
    func stopAsking(_ approval: PendingApproval) {
        turnApprovalsOff()
        core.resolveApproval(id: approval.id, approved: true)
    }""",
        """    func resolve(_ approval: PendingApproval, approved: Bool) {
        Task { await applyOwnerApproval(id: approval.id, approved: approved) }
    }

    func stopAsking(_ approval: PendingApproval) {
        Task { await applyOwnerApproval(id: approval.id, approved: true, stopAsking: true) }
    }

    private func applyOwnerApproval(id: String, approved: Bool, stopAsking: Bool = false) async {
        guard approvals.contains(where: { $0.id == id }) else { return }
        let mayProceed = approved ? await sitesBridge.canApplyOwnerApproval(id: id) : false
        guard approvals.contains(where: { $0.id == id }) else { return }
        if stopAsking, mayProceed { turnApprovalsOff() }
        if approved, !mayProceed {
            problem = String(activity: "Dot could not verify this approval. No approval was applied.")
        }
        core.resolveApproval(id: id, approved: mayProceed)
    }""",
        "Dot Bridge owner approval validation",
    )
    replace_once(
        app_model,
        """        // Don’t Ask Again is the owner's word about all later steps too, so it counts for a card whose
        // approval has already ended.
        if decision.stopAsking { turnApprovalsOff() }
        // A tap on an approval that already ended (answered in the app, or timed out) does nothing.""",
        """        // A decision applies only while its approval and task are still active.""",
        "Dot Bridge ignore ended owner decision",
    )
    replace_once(
        app_model,
        """            core.resolveApproval(id: decision.approvalID, approved: decision.approved)""",
        """            await applyOwnerApproval(id: decision.approvalID, approved: decision.approved, stopAsking: decision.stopAsking)""",
        "Dot Bridge route Live Activity and notification decisions",
    )


def patch_string_catalog(path: Path, entries: dict[str, dict[str, str]]) -> None:
    catalog = json.loads(path.read_text(encoding="utf-8"))
    strings = catalog["strings"]
    for key, values in entries.items():
        entry = strings.setdefault(key, {"extractionState": "manual", "localizations": {}})
        localizations = entry.setdefault("localizations", {})
        for language, value in values.items():
            localizations[language] = {"stringUnit": {"state": "translated", "value": value}}
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
