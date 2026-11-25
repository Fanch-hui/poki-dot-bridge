import Foundation

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

    func blockedScreen(_ elements: [Element]) -> Bool {
        elements.contains { ["Alert", "Sheet", "Dialog", "Popover"].contains($0.type) && !$0.frame.isEmpty }
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
              destination["ready_text"]?.string?.isEmpty != true,
              destination["ready_text"]?.string?.caseInsensitiveCompare(label) != .orderedSame else {
            throw ActionFailure(message: "navigate needs an app and an entry label; any destination landmark must be distinct", delivery: .notSent)
        }
        let ready = destination["ready_text"]?.string
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
            let tree = try await navigationScreen(bundle: bundle, until: until, entry: target, ready: ready)
            lastAll = tree.elements
            lastForeground = tree.foreground
            if let ready, tree.evidence == nil, visibleLabel(ready, in: tree.elements, screen: screen, allowSearchField: true) {
                runEndedOnARead = true
                return "navigate: \(opened.isEmpty ? "app already in front; " : "\(opened); ")destination \"\(ready)\" already visible"
            }
            let tapped: String
            if let evidence = tree.evidence {
                tapped = try await tapVisibleEntry(evidence, app: bundle, screen: screen, until: until)
            } else {
                var entry: [String: JSON] = ["label": .string(label)]
                if ready == nil {
                    let targets = PokiControlTargets(tree.elements, screen: screen)
                    let matches = tree.elements.filter {
                        ["Button", "Link", "Cell", "SearchField"].contains($0.type) && target.matches($0) &&
                            $0.label?.caseInsensitiveCompare(label) == .orderedSame && !targets.visibleFrame($0).isEmpty
                    }
                    guard matches.count == 1, let match = matches.first, targets.safePoint(for: match) != nil,
                          PokiOverlay.detect(in: tree.elements, screen: screen) == nil else {
                        throw ActionFailure(message: "no unique visible navigation entry; continue from the current screen", delivery: .notSent)
                    }
                    entry["type"] = .string(match.type)
                } else if let type = destination["type"]?.string, !type.isEmpty {
                    entry["type"] = .string(type)
                }
                let routine = try Self.pathRoutine(["goal": "Open destination", "steps": [["tap": .object(entry)]]])
                let initialTarget = routine.steps.first?.target.flatMap { target -> String? in
                    let matches = listable(tree.elements, screen).filter(target.matches)
                    let targets = PokiControlTargets(tree.elements, screen: screen)
                    guard matches.count == 1, let match = matches.first, targets.safePoint(for: match) != nil else { return nil }
                    return "\(match.key)@\(match.frame.described)"
                }
                tapped = try await replay(routine, params: [:], store: nil, until: until,
                                          expectedBundle: bundle, initialTarget: initialTarget)
            }
            entryTapped = true
            guard let ready else {
                return "navigate: \(opened.isEmpty ? "" : "\(opened); ")\(tapped); inspect the resulting screen"
            }
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

    private func navigationScreen(bundle: String, until: Double, entry: SkillTarget? = nil, ready: String? = nil) async throws
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
                        let page = try await navigationPage(tree.elements, screen: screen, until: deadline,
                                                            entry: entry, expectedBundle: bundle, ready: ready)
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

    func navigationPage(_ elements: [Element], screen: ScreenSize, until: Double, entry: SkillTarget? = nil,
                        expectedBundle: String? = nil, requireEntryProof: Bool = false, ready: String? = nil)
        async throws -> (elements: [Element], evidence: NavigationEntryEvidence?) {
        let pages = PokiPageVisibility(elements: elements, screen: screen)
        guard pages != nil || requireEntryProof else { return (elements, nil) }
        let left = until - now() - 0.2
        let screenshotAt = now()
        guard left >= 0.4, let png = try? await runner.screenshot(timeout: min(1.5, left)) else {
            throw ActionFailure(message: "overlapping pages could not be confirmed: screenshot unavailable or timed out; continue from the current screen", delivery: .notSent)
        }
        // Both reads use the same picture. A slow full-page read must not consume
        // the time available to identify a small icon caption in that picture.
        let caption = Task { [self] in
            guard let entry else { return nil as NavigationEntryEvidence? }
            return await captionEvidence(entry, elements: elements, screen: screen, png: png,
                                         screenshotAt: screenshotAt, until: until)
        }
        defer { caption.cancel() }
        guard let texts = try? await withDeadline(max(0.3, until - now() - 0.2), "checking overlapping pages", { [host] in
                  await host.recognizeText(inPNG: png)
              }) else {
            throw ActionFailure(message: "overlapping pages could not be confirmed: screenshot text recognition unavailable or timed out; continue from the current screenshot", delivery: .notSent)
        }
        let candidates = elements.filter { element in
            ["Button", "Link"].contains(element.type) && entry?.matches(element) == true
        }
        let target = candidates.count == 1 ? candidates.first : nil
        let resolution = pages?.filter(elements, using: texts, target: target)
        let visible = resolution?.elements
        func inVisiblePage(_ evidence: NavigationEntryEvidence) -> Bool {
            guard let visible else { return true }
            return visible.contains { $0.node == evidence.element.node }
        }
        if let entry, let evidence = visibleEntry(entry, in: elements, screen: screen, texts: texts,
                                                  observedAt: screenshotAt,
                                                  confirmedPage: resolution?.targetConfirmed == true),
           inVisiblePage(evidence) {
            return (elements, evidence)
        }
        if let label = entry?.label,
           !texts.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) == .orderedSame }),
           let evidence = await caption.value, inVisiblePage(evidence) {
            return (elements, evidence)
        }
        let matches = entry?.label.map { label in
            texts.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) == .orderedSame }
        } ?? []
        if let visible, !requireEntryProof, matches.count <= 1 { return (visible, nil) }
        if let visible, !requireEntryProof, let ready,
           visibleLabel(ready, in: visible, screen: screen, allowSearchField: true) {
            return (visible, nil)
        }
        let reason: String
        if entry?.label != nil {
            if matches.count > 1 {
                if !requireEntryProof, let entry, let expectedBundle, until - now() > 2 {
                    guard let tree = try? await runner.tree(timeout: min(config.readTimeout, until - now() - 0.2),
                                                            format: config.treeFormat, countsAsMiss: false) else {
                        throw ActionFailure(message: "the screen could not be refreshed after duplicate entry labels", delivery: .notSent)
                    }
                    guard tree.foreground.bundleID == expectedBundle, !blockedScreen(tree.elements),
                          PokiOverlay.detect(in: tree.elements, screen: screen) == nil else {
                        throw ActionFailure(message: "navigation target changed before its touch; continue from the current screen", delivery: .notSent)
                    }
                    return try await navigationPage(tree.elements, screen: screen, until: until,
                                                    entry: entry, requireEntryProof: true)
                }
                let candidates = elements.filter { ["Button", "Link"].contains($0.type) && entry?.matches($0) == true }
                let inTarget = candidates.count == 1 ? matches.filter {
                    let point = (x: $0.box.centre.x * screen.width, y: $0.box.centre.y * screen.height)
                    return candidates[0].frame.contains(point)
                }.count : 0
                reason = "the entry label appears more than once in the screenshot (\(matches.count) matches, \(inTarget) within the target)"
            } else if matches.isEmpty {
                reason = "the entry label could not be read in the screenshot or its icon caption"
            } else {
                reason = "the visible label could not be matched safely to its control"
            }
        } else {
            reason = "the screenshot did not identify a visible page"
        }
        throw ActionFailure(message: "overlapping pages could not be confirmed: \(reason); continue from the current screenshot", delivery: .notSent)
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
