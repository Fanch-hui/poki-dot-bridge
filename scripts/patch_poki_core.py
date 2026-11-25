"""Patch PokiCore input safety and screen observations for Dot Bridge."""

from pathlib import Path
from shutil import copy2

from patch_poki_keyboard import patch_keyboard
from patch_poki_loading import patch_loading
from patch_poki_nav import patch_navigation
from patch_poki_overlay import patch_overlay
from patch_poki_reach import patch_reach
from patch_poki_startup import patch_startup
from patch_poki_tap_latency import patch_tap_latency
from patch_poki_wait_reuse import patch_wait_reuse
from patch_poki_ui import replace_once


def patch_core_safety(bridge_root: Path, poki_root: Path) -> None:
    core = poki_root / "native/ios/PokiCore"
    source = core / "Sources/PokiCore"
    patch_overlay(bridge_root, core)
    patch_deadline(source / "Deadline.swift")
    patch_transaction_activity(source / "Approvals.swift")
    computer = source / "Computer.swift"
    patch_hit_testing(computer)
    patch_observations(source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiPageVisibility.swift", source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiControlTargets.swift", source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiDismissalEvidence.swift", source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiPointTargets.swift", source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiSearchFieldIdentity.swift", source)
    copy2(bridge_root / "ios/PokiAppIntegration/PokiSensitiveContext.swift", source)
    patch_control_targets(computer)
    patch_sensitive_context(source)
    patch_reach(source)
    patch_navigation(bridge_root, core)
    patch_loading(bridge_root, core)
    patch_startup(bridge_root, core)
    patch_keyboard(bridge_root, core)
    patch_tap_latency(bridge_root, core)
    patch_wait_reuse(bridge_root, core)
    replace_once(
        computer,
        r"""                    return ToolResult(text: "cancelled: the caller stopped waiting before the owner answered; nothing was sent from action \(at + 1).", jpeg: nil, isError: true)""",
        r"""                    let cancellation = "cancelled: the caller stopped waiting before the owner answered; nothing was sent from action \(at + 1)."
                    let text = ([cancellation] + did.map { "did: \($0)" }).joined(separator: "\n")
                    return ToolResult(text: text, jpeg: nil, isError: true)""",
        "PokiCore cancelled approval receipts",
    )
    replace_once(
        computer,
        """        for (i, action) in actions.enumerated() {
            let index = offset + i
            defer""",
        r"""        for (i, action) in actions.enumerated() {
            let index = offset + i
            guard !Task.isCancelled else {
                error = "cancelled before action \(index + 1); nothing more was sent"
                break
            }
            defer""",
        "PokiCore cancelled action batch",
    )
    replace_once(
        computer,
        """            return [(down, false, .stroke, (path.0, path.1))]""",
        """            // Native lists can repeat a payment button's label in the container.
            // A web surface can hide its own controls, so keep checking it.
            if Layout.scrollers.contains(down.type), down.type != "WebView" { return [] }
            return [(down, false, .stroke, (path.0, path.1))]""",
        "PokiCore scroll container",
    )
    # The release build skips tests; a full source checkout can run the same patch's regression cases.
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiCoreSafetyTests.swift", tests)
        copy2(bridge_root / "ios/PokiAppIntegration/PokiObservationTests.swift", tests)
        copy2(bridge_root / "ios/PokiAppIntegration/PokiControlTargetTests.swift", tests)
        copy2(bridge_root / "ios/PokiAppIntegration/PokiDismissalEvidenceTests.swift", tests)
        copy2(bridge_root / "ios/PokiAppIntegration/PokiPointTargetsTests.swift", tests)
        copy2(bridge_root / "ios/PokiAppIntegration/PokiSearchFieldIdentityTests.swift", tests)
        copy2(bridge_root / "ios/PokiAppIntegration/PokiGridCellTests.swift", tests)
        copy2(bridge_root / "ios/PokiAppIntegration/PokiNamedCardIdentityTests.swift", tests)
        copy2(bridge_root / "ios/PokiAppIntegration/PokiNavigationBarReachabilityTests.swift", tests)


def patch_transaction_activity(approvals: Path) -> None:
    replace_once(
        approvals,
        '"确认支付", "下单", "購買"',
        '"确认支付", "下单", "提交订单", "提交訂單", "購買"',
        "PokiCore order submission approval",
    )
    replace_once(
        approvals,
        r'''                // CJK words match anywhere; Latin words need whole-word boundaries.
                if w.unicodeScalars.contains(where: { $0.value > 0x2E80 }) { return word }''',
        r'''                // Activity counts describe past transactions; scan on for an actual action.
                if w.unicodeScalars.contains(where: { $0.value > 0x2E80 }) {
                    if PokiTransactionActivity.reports(lowered, word: w, range: range) {
                        search = range.upperBound..<lowered.endIndex
                        continue
                    }
                    return word
                }''',
        "PokiCore scan past transaction activity",
    )


def patch_sensitive_context(source: Path) -> None:
    computer = source / "Computer.swift"
    replace_once(
        computer,
        "        var elements: [Element]?\n    }\n\n    /// Each action of a batch",
        "        var elements: [Element]?\n        var allElements: [Element]?\n    }\n\n    /// Each action of a batch",
        "PokiCore retain the full tree for press classification",
    )
    replace_once(
        computer,
        "        let scan = SensitiveScan(front: elements.foreground, secureOnScreen: false, elements: listable(elements.all, screen))",
        "        let scan = SensitiveScan(front: elements.foreground, secureOnScreen: false, elements: listable(elements.all, screen), allElements: elements.all)",
        "PokiCore fresh press classification tree",
    )
    replace_once(
        computer,
        "            guard let reason = rules.reason(touching: press.element, typing: false, app: press.judged == .stroke ? nil : scan.front, secureOnScreen: false), reason != approved else { continue }",
        "            guard let reason = reasonForPress(press.element, at: press.location, in: scan, rules: rules, app: press.judged == .stroke ? nil : scan.front, secureOnScreen: false), reason != approved else { continue }",
        "PokiCore recheck the pressed action control",
    )
    replace_once(
        computer,
        "            if let r = rules.reason(touching: press.element, typing: false, app: press.judged == .stroke ? nil : scan.front, secureOnScreen: scan.secureOnScreen) { return r }",
        "            if let r = reasonForPress(press.element, at: press.location, in: scan, rules: rules, app: press.judged == .stroke ? nil : scan.front, secureOnScreen: scan.secureOnScreen) { return r }",
        "PokiCore check the pressed action control",
    )
    replace_once(
        computer,
        "-> [(element: Element?, atPoint: Bool, judged: Press)] {",
        "-> [(element: Element?, atPoint: Bool, judged: Press, location: (x: Double, y: Double)?)] {",
        "PokiCore retain the actual press location",
    )
    replace_once(
        computer,
        "-> (element: Element?, atPoint: Bool, judged: Press)? {",
        "-> (element: Element?, atPoint: Bool, judged: Press, location: (x: Double, y: Double)?)? {",
        "PokiCore retain tap location",
    )
    replace_once(
        computer,
        "func stroke(in spec: JSON?, _ direction: String, _ distance: String) -> [(element: Element?, atPoint: Bool, judged: Press)] {",
        "func stroke(in spec: JSON?, _ direction: String, _ distance: String) -> [(element: Element?, atPoint: Bool, judged: Press, location: (x: Double, y: Double)?)] {",
        "PokiCore retain stroke location",
    )
    replace_once(computer, "return (e, atPoint, .tap)", "return (e, atPoint, .tap, try? point(spec))", "PokiCore locate tap")
    replace_once(computer, "return [(down, false, .stroke)]", "return [(down, false, .stroke, (path.0, path.1))]", "PokiCore locate stroke")
    replace_once(
        computer,
        "return [(scan.elements == nil ? button : under(button.frame.centre), false, .button)]",
        "return [(scan.elements == nil ? button : under(button.frame.centre), false, .button, button.frame.centre)]",
        "PokiCore locate back button",
    )
    replace_once(
        source / "Routines.swift",
        r"                    scan = SensitiveScan(front: front, secureOnScreen: elements.contains(where: \.isSecure), elements: elements)",
        r"                    scan = SensitiveScan(front: front, secureOnScreen: elements.contains(where: \.isSecure), elements: elements, allElements: tree.elements)",
        "PokiCore routine press classification tree",
    )


def patch_control_targets(computer: Path) -> None:
    replace_once(
        computer,
        """        let visible = listable(reading.elements, screen, includeUnlabeledImages: selectedPane != nil)""",
        """        let targets = config.standaloneObservations ? PokiControlTargets(reading.elements, screen: screen) : nil
        let visible = listable(reading.elements, screen, includeUnlabeledImages: selectedPane != nil)
            .filter { targets?.visibleFrame($0).isEmpty != true }""",
        "PokiCore clip control lists to their scroll viewports",
    )
    replace_once(
        computer,
        r'''            return "\(mark)\(ref) \(e.type) \"\(text)\" \(e.frame.described)\(tag)"''',
        r'''            let row = targets?.annotation(for: e) ?? ""
            return "\(mark)\(ref) \(e.type) \"\(text)\" \(e.frame.described)\(tag)\(row)"''',
        "PokiCore identify repeated controls by their row",
    )
    replace_once(
        computer,
        """            let check = moved
                ? await pressNow(action, after: changed, approved: approved[index], until: until - config.readTimeout - 0.5)""",
        """            let targets = targetsToVerify(action)
            let pointTarget = pointTargetToVerify(action)
            let check = moved || !targets.isEmpty || pointTarget.requiresVerification
                ? await pressNow(action, after: changed, moved: moved, targets: targets,
                                 pointTarget: pointTarget, approved: approved[index], until: until - config.readTimeout - 0.5)""",
        "PokiCore verify numbered touches before dispatch",
    )
    replace_once(
        computer,
        """    func pressNow(_ action: JSON, after changed: (kind: String, at: Double)?, approved: String?, until: Double) async -> (problem: String?, backTarget: BackTarget?) {
        let rules = config.rules
        guard let kind = ActionKind(action), kind.presses(action), rules.enabled || kind == .back else { return (nil, nil) }""",
        """    func pressNow(_ action: JSON, after changed: (kind: String, at: Double)?, moved: Bool,
                  targets: [(ref: Int, element: Element)], pointTarget: PokiPointTargetSelection,
                  approved: String?, until: Double) async -> (problem: String?, backTarget: BackTarget?) {
        let rules = config.rules
        if case .blocked(let problem) = pointTarget { return (problem, nil) }
        guard let kind = ActionKind(action), kind.presses(action),
              rules.enabled || kind == .back || !targets.isEmpty || pointTarget.requiresVerification else { return (nil, nil) }""",
        "PokiCore require reference verification independent of approval settings",
    )
    replace_once(
        computer,
        """        guard let screen = size, let elements = await settledRead(until: min(until, now() + Self.settleWindow)) else {
            return ("the action before it may have changed the screen, and it could not be read again to check this one. Choose the remaining actions from the fresh screen below and send them in a new do", nil)
        }""",
        """        let elements: (all: [Element], foreground: Foreground)?
        if moved {
            elements = await settledRead(until: min(until, now() + Self.settleWindow))
        } else if until - now() >= 0.3,
                  let fresh = try? await runner.tree(timeout: min(1.5, until - now()), format: config.treeFormat,
                                                     workspace: selectedPane != nil, countsAsMiss: false) {
            elements = (fresh.elements, fresh.foreground)
        } else {
            elements = nil
        }
        guard let screen = size, var elements else {
            return ("the current screen could not be confirmed. Choose the remaining actions from the fresh screen below and send them in a new do", nil)
        }
        if case .guarded(let target) = pointTarget,
           let problem = pointTargetProblem(target, in: elements.all, foreground: elements.foreground, screen: screen) {
            return (problem, nil)
        }
        if let problem = controlProblem(targets, in: elements.all, foreground: elements.foreground, screen: screen) {
            guard selectedPane == nil, elements.foreground.bundleID == lastForeground?.bundleID,
                  let dismissal = await recheckCircularDismissal(targets, kind: kind, screen: screen, until: until) else {
                return (problem, nil)
            }
            elements = dismissal
        }""",
        "PokiCore recheck row identity and position against a live tree",
    )


def patch_observations(source: Path) -> None:
    replace_once(
        source / "Layout.swift",
        "if textOnlyTypes.contains(e.type), outer.text.contains(e.text) { drop.insert(i); break }",
        """// A list may repeat every item's title in one label. Keep the child's own hit area.
            if textOnlyTypes.contains(e.type), !Layout.scrollers.contains(outer.type),
               outer.text.contains(e.text) { drop.insert(i); break }""",
        "PokiCore preserve individually located list items",
    )
    replace_once(
        source / "Core.swift",
        "    public var quickRead: @Sendable () -> Bool = { true }",
        """    public var quickRead: @Sendable () -> Bool = { true }
    /// Include current controls in each observation even if they kept their references.
    public var standaloneObservations = false""",
        "PokiCore observation mode",
    )
    computer = source / "Computer.swift"
    replace_once(
        computer,
        '        if let side = reading.foreground?.pokiPane, side == "left" || side == "right" {',
        r'''        if config.standaloneObservations, let size, !inWorkspace {
            header.append("viewport: \(Int(size.width.rounded()))x\(Int(size.height.rounded())) points")
        }
        if let side = reading.foreground?.pokiPane, side == "left" || side == "right" {''',
        "PokiCore report the actual tap coordinate space",
    )
    replace_once(
        computer,
        "        let collapsed = Set(shown.filter",
        """        if config.standaloneObservations, !full, reading.png != nil, shown.contains(where: { list in
            Layout.scrollers.contains(list.type) && list.text.count > Self.textLimit &&
                !shown.contains { list.contains($0) && !$0.text.isEmpty && list.text.contains($0.text) }
        }) {
            notes.append("list items have no individual controls; use the current screenshot to locate them")
        }
        let collapsed = Set(shown.filter""",
        "PokiCore show the screenshot for a list exposed as a single summary",
    )
    replace_once(
        computer,
        "        if changes, !full, !fresh {",
        "        if changes, !full, !fresh, !config.standaloneObservations {",
        "PokiCore standalone control lists",
    )
    replace_once(
        computer,
        r"""            let limit = full ? 1000 : Self.lineLimit
            body = shown.indices.prefix(limit).map { line(assigned[$0]!, shown[$0], marks[$0]) }""",
        r"""            let limit = full ? 1000 : Self.lineLimit
            var indices = Array(shown.indices.prefix(limit))
            if config.standaloneObservations, shown.count > limit,
               let key = Self.returnKey(in: reading.elements), let index = shown.firstIndex(of: key), index >= limit {
                indices[limit - 1] = index
            }
            body = indices.map { line(assigned[$0]!, shown[$0], marks[$0]) }""",
        "PokiCore keep the keyboard return key in bounded lists",
    )
    replace_once(
        source / "Actions.swift",
        """        let all = seen.elements
        guard let keyboard = all.first(where: { $0.type == "Keyboard" }) else { return nil }""",
        """        return Self.returnKey(in: seen.elements)
    }

    static func returnKey(in all: [Element]) -> Element? {
        guard let keyboard = all.first(where: { $0.type == "Keyboard" }) else { return nil }""",
        "PokiCore current return key",
    )
    patch_picture_alignment(source / "Screen.swift", computer)
    patch_page_visibility(computer)


def patch_page_visibility(computer: Path) -> None:
    replace_once(
        computer,
        "        var popupTexts: [RecognizedText]?",
        "        var popupTexts: [RecognizedText]?\n        var pageTexts: [RecognizedText]?",
        "PokiCore page verification OCR",
    )
    replace_once(
        computer,
        """        }
        if let modal = modalOnly(reading.elements) { notes.append(modal) }""",
        """        } else if config.standaloneObservations, !inWorkspace, let size, let png = reading.png {
            let left = min(1.2, until - now() - 0.5)
            if left >= 0.3, let pages = PokiPageVisibility(elements: reading.elements, screen: size) {
                let host = self.host
                pageTexts = (try? await withDeadline(left, "checking overlapping pages", { await host.recognizeText(inPNG: png) })) ?? nil
                if let pageTexts, let visible = pages.filter(reading.elements, using: pageTexts) {
                    reading.elements = visible
                    notes.append("the screenshot confirms the visible page; controls from a covered page are omitted")
                }
            }
        }
        if let modal = modalOnly(reading.elements) { notes.append(modal) }""",
        "PokiCore filter covered pages before assigning references",
    )
    replace_once(
        computer,
        """                texts = []
            } else {""",
        """                texts = []
            } else if let pageTexts {
                texts = pageTexts
            } else {""",
        "PokiCore reuse page OCR for full reads",
    )


def patch_picture_alignment(screen: Path, computer: Path) -> None:
    replace_once(
        screen,
        "    var screenshotCompanion: ScreenshotCompanion?",
        "    var screenshotCompanion: ScreenshotCompanion?\n    var invalidatesReferences = false",
        "PokiCore stale reference marker",
    )
    replace_once(
        screen,
        "        switch await picturePart {",
        "        let firstPicture = await picturePart\n        switch firstPicture {",
        "PokiCore record the initial capture outcome",
    )
    replace_once(
        screen,
        "        if treeCame, reading.png != nil, let at = pictureAt.value, treeAt - at > 0.6, started + timeout - now() > 0.4 {",
        "        if treeCame, case .success? = firstPicture, let at = pictureAt.value, treeAt - at > 0.6, started + timeout - now() > 0.4 {",
        "PokiCore only compare captures with a shared timeline",
    )
    replace_once(
        screen,
        r"""                // The two pictures differ: the screen moved while the tree was read, so its frames
                // may be off; the model should go by text (scroll_to, numbers) rather than points.
                let before = PictureSketch(png: first), after = PictureSketch(png: again.data)
                if after.differs(from: before) {
                    let share = after.change(from: before).map { " (\(Int(($0.share * 100).rounded())) % of it)" } ?? ""
                    reading.notes.append("screen: moving\(share): the picture changed while the tree was read, so frames and points may be off; prefer scroll_to, wait_until and element numbers over [x, y] taps")
                }""",
        r"""                // The screenshots bracket a transition. Refresh the tree against the later image
                // while there is time, so the caller does not have to ask for the same screen again.
                if PictureSketch(png: again.data).differs(from: PictureSketch(png: first)) {
                    let left = started + timeout - now()
                    if left > 0.4, let fresh = try? await tree(timeout: min(1.5, left), format: format, workspace: workspace, countsAsMiss: false) {
                        reading.elements = fresh.elements
                        reading.foreground = fresh.foreground
                        reading.notes.append("the element tree was refreshed after the screen moved")
                    } else {
                        reading.elements = []
                        reading.foreground = nil
                        reading.invalidatesReferences = true
                        reading.notes.append("screen: moving; the latest screenshot is shown because the controls could not be refreshed")
                    }
                }""",
        "PokiCore reconcile a picture and tree sampled across a transition",
    )
    replace_once(
        computer,
        """                                        callEnds: until, allowHostPicture: !inWorkspace, workspace: inWorkspace)
        if let pane = selectedPane {""",
        """                                        callEnds: until, allowHostPicture: !inWorkspace, workspace: inWorkspace)
        if reading.invalidatesReferences {
            refs.removeAll()
            listed.removeAll()
            lastAll.removeAll()
            lastTreeAt = nil
            swipeUnread = true
        }
        if let pane = selectedPane {""",
        "PokiCore invalidate controls from before a detected transition",
    )


def patch_hit_testing(computer: Path) -> None:
    replace_once(
        computer,
        """        (elements ?? lastElements).filter { f in f.frame.x <= point.x && point.x <= f.frame.x + f.frame.width && f.frame.y <= point.y && point.y <= f.frame.y + f.frame.height }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }""",
        """        // As with CGRect, the right and bottom edges are outside a touch target.
        func hits(_ element: Element) -> Bool {
            let frame = element.frame
            return frame.x <= point.x && point.x < frame.maxX && frame.y <= point.y && point.y < frame.maxY
        }
        func smallest(_ candidates: [Element]) -> Element? {
            candidates.min { $0.frame.area < $1.frame.area }
        }
        let candidates = (elements ?? lastElements).filter(hits)
        let modal = (elements ?? lastAll).last {
            !$0.fromPicture && ($0.type == "Alert" || $0.type == "Sheet") && hits($0)
        }
        // WDA may still list a smaller control from the covered page behind a sheet.
        if let modal, let control = smallest(candidates.filter({ modal.contains($0) })) { return control }
        return smallest(candidates)""",
        "PokiCore foreground touch classification",
    )


def patch_deadline(path: Path) -> None:
    replace_once(
        path,
        """    let holder = LockedBox<(ResumeOnce<T>, Task<Void, Never>)?>(nil)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            let work = Task {
                do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
            }
            holder.value = (once, work)""",
        """    let holder = LockedBox<(cancelled: Bool, running: (ResumeOnce<T>, Task<Void, Never>)?)>((false, nil))
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            // The cancellation handler can run before this continuation registers the work.
            let registered = holder.update { state -> Task<Void, Never>? in
                guard !state.cancelled else { return nil }
                let task = Task {
                    do {
                        try Task.checkCancellation()
                        once.resume(.success(try await operation()))
                    } catch {
                        once.resume(.failure(error))
                    }
                }
                state.running = (once, task)
                return task
            }
            guard let work = registered else {
                once.resume(.failure(CancellationError()))
                return
            }""",
        "PokiCore deadline registration",
    )
    replace_once(
        path,
        """        if let (once, work) = holder.value, once.resume(.failure(CancellationError())) { work.cancel() }""",
        """        let running = holder.update { state in
            state.cancelled = true
            return state.running
        }
        if let (once, work) = running {
            work.cancel()
            once.resume(.failure(CancellationError()))
        }""",
        "PokiCore deadline cancellation",
    )
