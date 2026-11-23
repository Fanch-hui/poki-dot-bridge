#!/usr/bin/env python3
"""Builds the Dot-only app on top of a pinned Poki checkout."""

from __future__ import annotations

import pathlib
import shutil
import sys

from patch_poki_core import patch_core_safety
from patch_poki_ui import patch_dot_app, patch_dot_island, replace_once


def copy_tree_clean(src: pathlib.Path, dst: pathlib.Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(
        src,
        dst,
        ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"),
    )


def patch_project_base(poki_root: pathlib.Path) -> None:
    yml = poki_root / "native/ios-app/project-base.yml"
    replace_once(
        yml,
        "packages:\n  PokiCore:\n    path: ../ios/PokiCore",
        "packages:\n  PokiCore:\n    path: ../ios/PokiCore\n  PokiSitesBridge:\n    path: ../ios/PokiSitesBridge",
        "project-base package decl",
    )
    replace_once(
        yml,
        "      - target: PokiWidgets\n      - package: PokiCore",
        "      - target: PokiWidgets\n      - package: PokiCore\n      - package: PokiSitesBridge",
        "project-base target dep",
    )
    replace_once(
        yml,
        "        excludes: [LaunchArt/**]",
        "        excludes: [LaunchArt/**, Bear/Model/**, Entry/SendTaskIntent.swift, Entry/TalkHereIntent.swift]",
        "Dot Bridge app sources",
    )


def patch_live_core(poki_root: pathlib.Path) -> None:
    live_core = poki_root / "native/ios-app/Poki/Runtime/LiveCore.swift"
    replace_once(
        live_core,
        "        config.screenHistory = HistoryStore.agentSource\n",
        "        config.standaloneObservations = true\n",
        "Dot Bridge standalone observations",
    )
    replace_once(
        live_core,
        "    func start(relay: RelayAddress) { core.start(relay: relay) }",
        "    func start(relay: RelayAddress) { core.start(relay: relay) }\n    func handle(_ request: RelayRequest) async -> RelayResponse { await core.handle(request) }",
        "LiveCore.handle",
    )
    text = live_core.read_text(encoding="utf-8")
    if "extension LiveCore: @unchecked Sendable" not in text:
        live_core.write_text(text.rstrip() + "\n\nextension LiveCore: @unchecked Sendable {}\n", encoding="utf-8")


def patch_app_model(poki_root: pathlib.Path) -> None:
    app_model = poki_root / "native/ios-app/Poki/App/AppModel.swift"
    previous_finish_hook = """            onEmergencyStop: { [weak self] in
                self?.stopSession(keepEmergencyConnection: true)
            }
        )"""
    finish_hook = """            onEmergencyStop: { [weak self] in
                self?.stopSession(keepEmergencyConnection: true)
            },
            onAutomationFinish: { [weak self] session in
                await self?.finishDotAutomation(session: session) ?? false
            }
        )"""
    if "lazy var sitesBridge: PokiSitesBridgeSession" in app_model.read_text(encoding="utf-8"):
        replace_once(app_model, previous_finish_hook, finish_hook, "AppModel.sitesBridge completion hook")
    replace_once(
        app_model,
        "import PokiCore",
        "import PokiCore\nimport PokiSitesBridge",
        "AppModel import",
    )
    replace_once(
        app_model,
        "    private let core: LiveCore",
        """    private let core: LiveCore
    @ObservationIgnored
    lazy var sitesBridge: PokiSitesBridgeSession = {
        let liveCore = self.core
        return PokiSitesBridgeSession(
            connectorId: "chatgpt-dot-sites",
            runnerStateProvider: { [weak self] in
                await MainActor.run {
                    guard let self else { return "idle" }
                    return PokiRunnerStateMapper.normalize(
                        self.runner.state,
                        awaitingAuthorization: self.passcodeHint,
                        declined: InProcessWDA.automationDeclined,
                        inProcessReady: self.hasOpenInProcessSession || self.canStartTasks
                    )
                }
            },
            rpcHandler: { body, headers in
                let req = RelayRequest(
                    id: UUID().uuidString.lowercased(),
                    method: "POST",
                    headers: headers,
                    body: body
                )
                let res = await liveCore.handle(req)
                return (res.status, res.headers, res.body)
            },
            onEmergencyStop: { [weak self] in
                self?.stopSession(keepEmergencyConnection: true)
            },
            onAutomationFinish: { [weak self] session in
                await self?.finishDotAutomation(session: session) ?? false
            }
        )
    }()""",
        "AppModel.sitesBridge property",
    )
    finish_method = """    private func canFinishDotAutomation(session: String) -> Bool {
        !Task.isCancelled && automationPath == .inProcess && sessionOn && !runnerPaused &&
            inProcessSession == .open && !inProcessWarming && !probeDriven &&
            !chatTaskActive && !voice.isOn && stepUnderWay == nil && activityText == "Idle" &&
            approvals.isEmpty && checking.isEmpty && handoffText == nil && endingTasks == 0 &&
            outsideAgentsAtWork.keys.allSatisfy { $0 == session } &&
            !(AskPoki.app === self && AskPoki.chat?.isRunningInSplitView == true)
    }

    func finishDotAutomation(session: String) async -> Bool {
        guard canFinishDotAutomation(session: session) else { return false }
        let activityAtFinish = lastAgentActivity
        endingTasks += 1
        _ = await core.finishTask(switching: false, localSession: session, ifNoLocalWorkspace: true)
        endingTasks -= 1
        guard lastAgentActivity == activityAtFinish, canFinishDotAutomation(session: session) else { return false }
        outsideAgentsAtWork.removeValue(forKey: session)
        activity.finishNow(alert: false, confirmedWhileIdle: true)
        closeAfterTask("the Dot task ended")
        return true
    }

"""
    replace_once(
        app_model,
        "    private func closeAfterTask(_ why: String) {",
        finish_method + "    private func closeAfterTask(_ why: String) {",
        "AppModel Dot task completion",
    )
    replace_once(
        app_model,
        "    func becameActive() {\n        inFront = true",
        "    func becameActive() {\n        inFront = true\n        sitesBridge.handleScenePhase(.active, automationEnabled: sessionOn)",
        "AppModel.becameActive",
    )
    replace_once(
        app_model,
        "    func wentToBackground() {\n        inFront = false",
        "    func wentToBackground() {\n        inFront = false\n        sitesBridge.handleScenePhase(.background, automationEnabled: sessionOn)",
        "AppModel.wentToBackground",
    )
    replace_once(
        app_model,
        "    func startSession(reconnectLocal: Bool = true) {\n        guard !passcodeConfirmationPending, !sessionOn, !sessionStarting else { return }",
        """    func startSession(reconnectLocal: Bool = true) {
        guard !passcodeConfirmationPending, !sessionOn, !sessionStarting else { return }
        guard sitesBridge.isPaired else { problem = AppLocalization.text("Pair with Dot first."); return }""",
        "AppModel.startSession",
    )
    replace_once(
        app_model,
        "    private func checkSessionStartPreconditions() -> (pairing: String, relay: RelayAddress?)? {",
        "    private func checkSessionStartPreconditions() -> String? {",
        "AppModel.checkSessionStartPreconditions result",
    )
    replace_once(
        app_model,
        """        // The chat's own model loop needs no relay; agents on a computer do.
        let relay = activeRelay
        guard relay != nil || ModelKeys.hasUsableKey else { problem = Self.noRelay; return nil }
        return (pairing, relay)""",
        """        guard sitesBridge.isPaired else { problem = AppLocalization.text("Pair with Dot first."); return nil }
        return pairing""",
        "AppModel.checkSessionStartPreconditions pairing",
    )
    replace_once(
        app_model,
        "        guard let (pairing, relay) = checkSessionStartPreconditions() else { return }",
        "        guard let pairing = checkSessionStartPreconditions() else { return }",
        "AppModel.beginSession preconditions",
    )
    replace_once(
        app_model,
        "        if let relay { core.start(relay: relay) }",
        "        sitesBridge.setDDIMounted(true)\n        sitesBridge.start()",
        "AppModel.beginSession",
    )
    replace_once(
        app_model,
        "    private func turnOnIfWanted() {",
        """    func restoreDotAutomationIfNeeded() {
        turnOnIfWanted()
    }

    private func turnOnIfWanted() {""",
        "AppModel restored Dot pairing",
    )
    replace_once(
        app_model,
        "if wantsOn, !sessionOn, pairingPath != nil, diskImage.hasFiles {",
        "if wantsOn, sitesBridge.isPaired, !sessionOn, pairingPath != nil, diskImage.hasFiles {",
        "AppModel restore preconditions",
    )
    replace_once(
        app_model,
        "        sessionOn || HistoryCapture.isEnabled ? loopback.resume(every: 6) : loopback.pause()",
        "        sessionOn ? loopback.resume(every: 6) : loopback.pause()",
        "Dot Bridge background connection",
    )
    replace_once(
        app_model,
        "        core.stop()\n        launcher.stop()\n        await activity.end",
        "        core.stop()\n        sitesBridge.stop()\n        launcher.stop()\n        await activity.end",
        "AppModel wind down for update",
    )
    replace_once(
        app_model,
        "    func stopSession() {\n        let awaitingAuthorization",
        """    func stopSession(keepEmergencyConnection: Bool = false) {
        // Emergency stop keeps polling so the bridge can receive Dot's resume.
        if !keepEmergencyConnection { sitesBridge.stop() }
        let awaitingAuthorization""",
        "AppModel stop local control and polling",
    )
    replace_once(
        app_model,
        "        if !inFront, !HistoryCapture.isEnabled { loopback.pause() }",
        "        if !inFront { loopback.pause() }",
        "Dot Bridge pause local connection",
    )
    replace_once(
        app_model,
        "    private func askOwner(_ approval: PendingApproval) {\n        approvals.append(approval)",
        """    private func askOwner(_ approval: PendingApproval) {
        approvals.append(approval)
        sitesBridge.reportApprovalRequested(
            id: approval.id,
            app: approval.app,
            summary: approval.summary,
            reason: approval.reason,
            expiresAt: approval.expires
        )""",
        "AppModel.askOwner",
    )
    replace_once(
        app_model,
        "        case .approvalEnded(let id, let approved):\n            lastApprovalAnswered = Date()",
        "        case .approvalEnded(let id, let approved):\n            lastApprovalAnswered = Date()\n            sitesBridge.reportApprovalEnded()",
        "AppModel.approvalEnded",
    )
    replace_once(
        app_model,
        "        case .handoffRequested(let id, let kind, let text, let app):\n            lastAgentActivity = Date(); lastStepAt = Date()",
        "        case .handoffRequested(let id, let kind, let text, let app):\n            lastAgentActivity = Date(); lastStepAt = Date()\n            sitesBridge.reportHandoffRequested(id: id, kind: kind, text: text, app: app)",
        "AppModel.handoffRequested",
    )
    replace_once(
        app_model,
        "        case .handoffEnded(let id, let how):\n            lastAgentActivity = Date(); lastStepAt = Date()",
        "        case .handoffEnded(let id, let how):\n            lastAgentActivity = Date(); lastStepAt = Date()\n            sitesBridge.reportHandoffEnded()",
        "AppModel.handoffEnded",
    )


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: patch-poki-upstream.py <bridge-repo-root> <poki-upstream-checkout>")
    bridge_root = pathlib.Path(sys.argv[1]).resolve()
    poki_root = pathlib.Path(sys.argv[2]).resolve()

    copy_tree_clean(bridge_root / "ios/PokiSitesBridge", poki_root / "native/ios/PokiSitesBridge")
    for fname in ("PokiCoreBridgeExecutor.swift", "SitesBridgeSettingsView.swift"):
        shutil.copy2(
            bridge_root / "ios/PokiAppIntegration" / fname,
            poki_root / "native/ios-app/Poki/Connect" / fname,
        )

    patch_project_base(poki_root)
    patch_live_core(poki_root)
    patch_app_model(poki_root)
    patch_dot_app(bridge_root, poki_root)
    patch_dot_island(bridge_root, poki_root)
    patch_core_safety(bridge_root, poki_root)
    print(f"Applied the Dot Bridge app and Live Activity to {poki_root}.")


if __name__ == "__main__":
    main()
