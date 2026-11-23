import Foundation

private struct NavigationEntryEvidence {
    let target: SkillTarget
    let element: Element
    let point: (x: Double, y: Double)
    let observedAt: Double
}

extension Computer {
    private static let selectionActions = [
        "选规格", "选择规格", "選規格", "選擇規格", "加入购物", "添加到购物", "添加至购物",
        "加入購物", "添加到購物", "添加至購物", "加购", "加購", "add to cart",
        "add to basket", "choose option", "select option",
    ]
    func expandSearch(_ spec: JSON) throws -> [JSON] {
        guard let query = spec["text"]?.string, !query.isEmpty,
              let supplied = spec["result_texts"]?.array, !supplied.isEmpty, supplied.count <= 6 else {
            throw ActionFailure(message: "search_submit requires text and one to six exact result labels", delivery: .notSent)
        }
        let labels = supplied.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard labels.count == supplied.count, labels.allSatisfy({ !$0.isEmpty && $0.caseInsensitiveCompare(trimmedQuery) != .orderedSame }) else {
            throw ActionFailure(message: "search_submit requires result labels distinct from the query", delivery: .notSent)
        }
        guard lastForeground?.bundleID != nil, let screen = size else {
            throw ActionFailure(message: "search_submit needs a current observation of the app", delivery: .notSent)
        }
        guard let ref = spec["ref"]?.int, let field = refs[ref],
              ["SearchField", "TextField", "TextView"].contains(field.type), Self.isSearch(field), !field.fromPicture else {
            throw ActionFailure(message: "search_submit needs a reference to a current search field", delivery: .notSent)
        }
        let present = labels.filter { visibleLabel($0, in: lastAll, screen: screen) }
        var typing: [String: JSON] = ["type": .string(query)]
        for key in ["ref", "clear", "via"] {
            if let value = spec[key] { typing[key] = value }
        }
        return [
            .object(typing),
            ["key": "return"],
            ["wait_until": ["texts_any": .array(labels.map(JSON.string)), "present_before": .array(present.map(JSON.string)), "ms": 5000]],
        ]
    }

    private func visibleLabel(_ label: String, in elements: [Element], screen: ScreenSize,
                              allowSearchField: Bool = false) -> Bool {
        let targets = PokiControlTargets(elements, screen: screen)
        let layout = Layout(all: elements, screen: screen)
        let fields: Set<String> = ["TextField", "SearchField", "SecureTextField", "TextView"]
        return elements.contains { element in
            guard !element.fromPicture, !Computer.containers.contains(element.type) else { return false }
            if fields.contains(element.type) {
                guard allowSearchField, element.type == "SearchField",
                      let fieldLabel = element.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                      fieldLabel.caseInsensitiveCompare(label) == .orderedSame,
                      element.value?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) != .orderedSame else {
                    return false
                }
            } else if element.text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) != .orderedSame {
                return false
            }
            let frame = targets.visibleFrame(element)
            return !frame.isEmpty && !layout.covers(element).contains { $0.frame.contains(frame.centre) }
        }
    }

    private func blockedScreen(_ elements: [Element]) -> Bool {
        elements.contains { ["Alert", "Sheet"].contains($0.type) && !$0.frame.isEmpty }
    }

    func waitForResultLabels(_ spec: JSON, until: Double) async throws -> String {
        guard let labels = spec["texts_any"]?.array?.compactMap(\.string), !labels.isEmpty else {
            throw ActionFailure(message: "wait_until needs result labels", delivery: .notSent)
        }
        let started = now()
        let limit = min(until - 0.9, started + min(10, max(0.2, (spec["ms"]?.double ?? 5000) / 1000)))
        let screen = try await screenSize(until: until)
        let expectedApp = lastForeground?.bundleID
        var awaitingChange = Set(spec["present_before"]?.array?.compactMap(\.string) ?? [])
        while now() < limit {
            try Task.checkCancellation()
            if let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, limit - now())), format: config.treeFormat, countsAsMiss: false) {
                guard expectedApp == nil || tree.foreground.bundleID == expectedApp else {
                    throw ActionFailure(message: "search was submitted, but the foreground app changed", delivery: .notSent)
                }
                if blockedScreen(tree.elements) {
                    throw ActionFailure(message: "search was submitted, but a dialog is in front", delivery: .notSent)
                }
                let visible = try await navigationVisibleElements(tree.elements, screen: screen, until: limit)
                awaitingChange = awaitingChange.filter { visibleLabel($0, in: visible, screen: screen) }
                if let label = labels.first(where: { !awaitingChange.contains($0) && visibleLabel($0, in: visible, screen: screen) }) {
                    return "wait_until: result \"\(label)\" appeared after \(Int(((now() - started) * 1000).rounded())) ms"
                }
            }
            if now() < limit { await sleep(seconds: min(0.15, limit - now())) }
        }
        throw ActionFailure(message: "search was submitted; result labels did not appear before the deadline. Continue from the current screen", delivery: .notSent)
    }

    func fastNavigate(_ spec: JSON, until: Double) async throws -> String {
        guard let app = spec["app"]?.string, !app.isEmpty,
              let destination = spec["destination"],
              let label = destination["label"]?.string, !label.isEmpty,
              let ready = destination["ready_text"]?.string, !ready.isEmpty,
              ready.caseInsensitiveCompare(label) != .orderedSame else {
            throw ActionFailure(message: "navigate needs an app, an entry label, and a distinct destination label", delivery: .notSent)
        }
        guard !Self.selectionActions.contains(where: { label.lowercased().contains($0) }) else {
            throw ActionFailure(message: "navigate requires a navigation entry; choosing options or adding items needs a separate action", delivery: .notSent)
        }
        guard let bundle = config.resolveApp(app) ?? (app.contains(".") && !app.contains(" ") ? app : nil) else {
            throw ActionFailure(message: "navigate: app \"\(app)\" is not known", delivery: .notSent)
        }
        guard !config.isPoki(Foreground(bundleID: bundle, name: nil)) else {
            throw ActionFailure(message: "navigate cannot send actions into Poki", delivery: .notSent)
        }
        let screen = try await screenSize(until: until)
        let fresh = spec["fresh"]?.bool == true
        var opened = ""
        var needsLaunch = fresh
        if !fresh {
            let info = try? await runner.raw("GET", "/wda/activeAppInfo",
                                             timeout: min(config.readTimeout, max(0.3, until - now())), countsAsMiss: false)
            needsLaunch = info?["bundleId"]?.string != bundle
        }
        if needsLaunch {
            let launch: JSON = ["launch": ["bundle": .string(bundle), "fresh": .bool(fresh)]]
            let started = now()
            let (_, description) = try await perform(launch, until: min(until, now() + actionCap(launch)))
            opened = "\(description) (sent, \(Int(((now() - started) * 1000).rounded())) ms)"
        }
        var entryTapped = false
        do {
            let target = SkillTarget(type: destination["type"]?.string ?? SkillTarget.anyType, label: label)
            let tree = try await navigationScreen(bundle: bundle, until: until, entry: target)
            lastAll = tree.elements
            lastForeground = tree.foreground
            if tree.evidence == nil, visibleLabel(ready, in: tree.elements, screen: screen, allowSearchField: true) {
                runEndedOnARead = true
                return "navigate: \(opened.isEmpty ? "app already in front; " : "\(opened); ")destination \"\(ready)\" already visible"
            }
            let tapped: String
            if let evidence = tree.evidence {
                tapped = try await tapVisibleEntry(evidence, app: bundle, screen: screen, until: until)
            } else {
                var entry: [String: JSON] = ["label": .string(label)]
                if let type = destination["type"]?.string, !type.isEmpty { entry["type"] = .string(type) }
                let routine = try Self.pathRoutine(["goal": "Open destination", "steps": [["tap": .object(entry)]]])
                tapped = try await replay(routine, params: [:], store: nil, until: until, expectedBundle: bundle)
            }
            entryTapped = true
            let deadline = min(until - 0.9, now() + 3)
            while now() < deadline {
                let updated = try await navigationScreen(bundle: bundle, until: deadline)
                if visibleLabel(ready, in: updated.elements, screen: screen, allowSearchField: true) {
                    runEndedOnARead = true
                    return "navigate: \(opened.isEmpty ? "" : "\(opened); ")\(tapped); destination \"\(ready)\" visible"
                }
                await sleep(seconds: min(0.15, max(0, deadline - now())))
            }
            throw ActionFailure(message: "destination \"\(ready)\" did not appear; continue from the current screen", delivery: .sent)
        } catch let failure as ActionFailure {
            if entryTapped {
                throw ActionFailure(message: "navigate: entry was tapped; \(failure.message)", delivery: .sent)
            }
            if !opened.isEmpty && failure.delivery == .notSent {
                throw ActionFailure(message: "navigate: app launch was sent; \(failure.message)", delivery: .sent)
            }
            throw failure
        }
    }

    private func navigationScreen(bundle: String, until: Double, entry: SkillTarget? = nil) async throws
        -> (elements: [Element], foreground: Foreground, evidence: NavigationEntryEvidence?) {
        var lastProblem = "the target app is not yet in front"
        let deadline = min(until - 0.3, now() + 4)
        while now() < deadline {
            try Task.checkCancellation()
            if let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, deadline - now())), format: config.treeFormat, countsAsMiss: false) {
                if blockedScreen(tree.elements) {
                    throw ActionFailure(message: "navigate stopped: a dialog is in front; continue from the current screen", delivery: .notSent)
                }
                if tree.foreground.bundleID == bundle, !tree.elements.isEmpty {
                    if let screen = size {
                        let page = try await navigationPage(tree.elements, screen: screen, until: deadline, entry: entry)
                        return (page.elements, tree.foreground, page.evidence)
                    }
                    return (tree.elements, tree.foreground, nil)
                }
                lastProblem = "the target app could not be confirmed in front"
            }
            if now() < deadline { await sleep(seconds: min(0.15, deadline - now())) }
        }
        throw ActionFailure(message: "navigate stopped: \(lastProblem); continue from the current screen", delivery: .notSent)
    }

    func navigationVisibleElements(_ elements: [Element], screen: ScreenSize, until: Double) async throws -> [Element] {
        try await navigationPage(elements, screen: screen, until: until).elements
    }

    private func navigationPage(_ elements: [Element], screen: ScreenSize, until: Double, entry: SkillTarget? = nil)
        async throws -> (elements: [Element], evidence: NavigationEntryEvidence?) {
        guard let pages = PokiPageVisibility(elements: elements, screen: screen) else { return (elements, nil) }
        let left = until - now() - 0.2
        let screenshotAt = now()
        guard left >= 0.4,
              let png = try? await runner.screenshot(timeout: min(1.5, left)),
              let texts = try? await withDeadline(max(0.3, until - now() - 0.2), "checking overlapping pages", { [host] in
                  await host.recognizeText(inPNG: png)
              }) else {
            throw ActionFailure(message: "overlapping pages could not be confirmed; continue from the current screenshot", delivery: .notSent)
        }
        if let visible = pages.filter(elements, using: texts) { return (visible, nil) }
        if let entry, let evidence = visibleEntry(entry, in: elements, screen: screen, texts: texts,
                                                  observedAt: screenshotAt) {
            return (elements, evidence)
        }
        throw ActionFailure(message: "overlapping pages could not be confirmed; continue from the current screenshot", delivery: .notSent)
    }

    private func visibleEntry(_ target: SkillTarget, in elements: [Element], screen: ScreenSize,
                              texts: [RecognizedText], observedAt: Double) -> NavigationEntryEvidence? {
        guard let label = target.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        let candidates = elements.filter { ["Button", "Link"].contains($0.type) && target.matches($0) }
        guard candidates.count == 1, let element = candidates.first,
              element.label?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) == .orderedSame else { return nil }
        let targets = PokiControlTargets(elements, screen: screen)
        guard let point = targets.safePoint(for: element), entryHasNoCompetingControl(element, point, elements, targets) else { return nil }
        let matches = texts.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) == .orderedSame }
        guard matches.count == 1, let match = matches.first else { return nil }
        let box = Rect(x: match.box.x * screen.width, y: match.box.y * screen.height,
                       width: match.box.width * screen.width, height: match.box.height * screen.height)
        let frame = targets.visibleFrame(element)
        guard !box.isEmpty, frame.contains((box.x, box.y)), frame.contains((box.maxX, box.maxY)),
              box.contains(point) else { return nil }
        return NavigationEntryEvidence(target: target, element: element, point: point, observedAt: observedAt)
    }

    private func entryHasNoCompetingControl(_ entry: Element, _ point: (x: Double, y: Double), _ elements: [Element],
                                            _ targets: PokiControlTargets) -> Bool {
        let contact = Rect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        let actionable: Set<String> = ["Button", "Link", "TextField", "SearchField", "SecureTextField",
                                       "Switch", "Toggle", "CheckBox", "RadioButton", "Slider", "TextView",
                                       "Stepper", "PickerWheel", "ComboBox", "PopUpButton", "MenuButton", "Tab"]
        return !elements.contains {
            $0.node != entry.node && actionable.contains($0.type) && !targets.visibleFrame($0).intersection(contact).isEmpty
        }
    }

    private func tapVisibleEntry(_ evidence: NavigationEntryEvidence, app: String, screen: ScreenSize,
                                 until: Double) async throws -> String {
        try Task.checkCancellation()
        guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, until - now() - 0.2)),
                                                format: config.treeFormat, countsAsMiss: false),
              tree.foreground.bundleID == app, !blockedScreen(tree.elements), now() - evidence.observedAt <= 2.5 else {
            throw ActionFailure(message: "navigation target changed before its touch; continue from the current screen", delivery: .notSent)
        }
        let matching = tree.elements.filter { ["Button", "Link"].contains($0.type) && evidence.target.matches($0) }
        guard matching.count == 1, let entry = matching.first,
              entry.key == evidence.element.key, entry.identifier == evidence.element.identifier,
              entry.frame == evidence.element.frame else {
            throw ActionFailure(message: "navigation target changed before its touch; continue from the current screen", delivery: .notSent)
        }
        let targets = PokiControlTargets(tree.elements, screen: screen)
        guard let point = targets.safePoint(for: entry), point.x == evidence.point.x, point.y == evidence.point.y,
              entryHasNoCompetingControl(entry, point, tree.elements, targets) else {
            throw ActionFailure(message: "navigation target is no longer safely tappable; continue from the current screen", delivery: .notSent)
        }
        lastAll = tree.elements
        lastForeground = tree.foreground
        refs[Self.runRef] = entry
        verifiedTargets[Self.runRef] = (entry, point)
        defer { refs[Self.runRef] = nil; verifiedTargets[Self.runRef] = nil }
        let tap: JSON = ["tap": .number(Double(Self.runRef))]
        var scan = SensitiveScan(front: tree.foreground, secureOnScreen: tree.elements.contains(where: \.isSecure),
                                 allElements: tree.elements)
        if let reason = sensitive(tap, &scan) {
            throw ActionFailure(message: "navigation entry needs the owner's approval (\(reason)); choose it from the current screen", delivery: .notSent)
        }
        try Task.checkCancellation()
        let description: String
        do {
            (_, description) = try await perform(tap, until: until)
        } catch let failure as RunnerError {
            throw ActionFailure(message: "navigation entry failed (\(failure))", delivery: failure.delivery)
        }
        let recordedTarget = evidence.target.type == SkillTarget.anyType ? SkillTarget(entry) : evidence.target
        let step = SkillStep(action: ["tap": ["ref": "@"]], target: recordedTarget, app: app, secret: nil)
        trace.append(RecordedStep(step: step, typed: nil, keysBefore: []))
        return "\(description) (sent; screen-confirmed entry)"
    }

    func launchReadyPause(_ pause: Double, bundle: String) async -> (waited: Double, settled: Bool) {
        let began = now()
        guard let screen = size else { await sleep(seconds: pause); return (pause, false) }
        let viewport = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        var previous: String?
        while now() - began < pause {
            let left = pause - (now() - began)
            guard left > 0.3 else { break }
            if let tree = try? await runner.tree(timeout: left, format: config.treeFormat, countsAsMiss: false),
               tree.foreground.bundleID == bundle, !blockedScreen(tree.elements) {
                let controls = listable(tree.elements, screen).filter {
                    !Computer.containers.contains($0.type) && !$0.text.isEmpty && !$0.frame.intersection(viewport).isEmpty
                }
                let signature = controls.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
                if !signature.isEmpty, signature == previous { return (now() - began, true) }
                previous = signature.isEmpty ? nil : signature
            } else {
                previous = nil
            }
            let leftAfterRead = pause - (now() - began)
            if leftAfterRead > 0 { await sleep(seconds: min(0.06, leftAfterRead)) }
        }
        let remaining = pause - (now() - began)
        if remaining > 0 { await sleep(seconds: remaining) }
        return (now() - began, false)
    }
}
