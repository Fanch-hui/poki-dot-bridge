"""Keep the observed and dispatched touch target in agreement."""

from pathlib import Path

from patch_poki_ui import replace_once


def patch_reach(source: Path) -> None:
    computer = source / "Computer.swift"
    actions = source / "Actions.swift"
    routines = source / "Routines.swift"
    layout = source / "Layout.swift"
    replace_once(
        layout,
        "            let encloses = c.frame.x <= target.frame.x + 0.5 && c.frame.y <= target.frame.y + 0.5 && c.frame.maxX >= target.frame.maxX - 0.5 && c.frame.maxY >= target.frame.maxY - 0.5",
        """            // Accessibility can round a bar and its controls to slightly different edges.
            let isLargeBar = Self.bars.contains(c.type) &&
                (c.frame.width >= 2 * target.frame.width || c.frame.height >= 2 * target.frame.height)
            let tolerance = isLargeBar ? 2.0 : 0.5
            let encloses = c.frame.x <= target.frame.x + tolerance && c.frame.y <= target.frame.y + tolerance && c.frame.maxX >= target.frame.maxX - tolerance && c.frame.maxY >= target.frame.maxY - tolerance""",
        "PokiCore tolerate rounded bar and control frames",
    )
    replace_once(
        computer,
        "    var lastElements: [Element] { listed.map(\\.element) }",
        """    var verifiedTargets: [Int: (element: Element, point: (x: Double, y: Double))] = [:]
    var lastCircularDismissals: (readAt: Double, nodes: Set<Int>)?
    var lastElements: [Element] { listed.map(\\.element) }""",
        "PokiCore use the verified target for the actual touch",
    )
    replace_once(
        computer,
        '            let row = targets?.annotation(for: e) ?? ""',
        '''            var reachability = targets?.reachabilityAnnotation(for: e, listed: listed) ?? ""
            if circularDismissals.contains(e.node) {
                reachability = reachability.replacingOccurrences(of: " [covered]", with: "")
            }
            let row = reachability + (targets?.annotation(for: e) ?? "")''',
        "PokiCore report covered controls in the first read",
    )
    replace_once(
        computer,
        "        func line(_ ref: Int, _ e: Element, _ mark: String) -> String {",
        r"""        var circularDismissals: Set<Int> = []
        if treeRead, let targets, selectedPane == nil, !reading.invalidatesReferences, let png = reading.png {
            circularDismissals = Set(shown.filter { element in
                PokiDismissalEvidence.matches(element) && targets.safePoint(for: element) == nil &&
                    PokiDismissalEvidence.corroborates(element, in: reading.elements, screen: screen, png: png)
            }.map(\.node))
        }
        lastCircularDismissals = lastTreeAt.map { (readAt: $0, nodes: circularDismissals) }

        func line(_ ref: Int, _ e: Element, _ mark: String) -> String {""",
        "PokiCore remember dismissal controls confirmed in this observation",
    )
    replace_once(
        computer,
        "            let targets = targetsToVerify(action)",
        """            verifiedTargets.removeAll()
            defer { verifiedTargets.removeAll() }
            let targets = targetsToVerify(action)""",
        "PokiCore scope verified points to one action",
    )
    replace_once(
        actions,
        """        let e = try element(ref)
        if e.fromPicture || size == nil { return e.frame.centre }
        let layout = self.layout""",
        """        let e = try element(ref)
        if let verified = verifiedTargets[ref] { return verified.point }
        if e.fromPicture || size == nil { return e.frame.centre }
        if config.standaloneObservations, let size {
            guard let point = PokiControlTargets(lastAll, screen: size).safePoint(for: e) else {
                throw ActionFailure(message: "not_hittable: element \\(ref) is covered or outside its visible area; nothing was sent", delivery: .notSent)
            }
            return point
        }
        let layout = self.layout""",
        "PokiCore use a clear visible point",
    )
    replace_once(
        actions,
        "        return refs[ref]?.frame\n    }",
        "        return verifiedTargets[ref]?.element.frame ?? refs[ref]?.frame\n    }",
        "PokiCore use the verified target frame",
    )
    replace_once(
        routines,
        "        steps: for (index, step) in skill.steps.enumerated() {",
        """        steps: for (index, step) in skill.steps.enumerated() {
            defer { verifiedTargets[Self.runRef] = nil }""",
        "PokiCore scope path target points to one step",
    )
    replace_once(
        routines,
        "                var found: Element?",
        """                var found: Element?
                var foundPoint: (x: Double, y: Double)?""",
        "PokiCore retain the chosen path point",
    )
    replace_once(
        routines,
        "                    var elements: [Element] = []\n                    var early = false",
        """                    var elements: [Element] = []
                    var lastTargets: PokiControlTargets?
                    var early = false""",
        "PokiCore keep path reachability for the latest tree",
    )
    replace_once(
        routines,
        "                        lastForeground = tree.foreground\n                        var matches = elements.filter(target.matches)",
        """                        lastForeground = tree.foreground
                        let targets = PokiControlTargets(tree.elements, screen: screen)
                        lastTargets = targets
                        var matches = elements.filter(target.matches)""",
        "PokiCore reuse path reachability for each tree",
    )
    replace_once(
        routines,
        """                            let reachable = matches.filter { layout.touchPoint($0) != nil }""",
        """                            let reachable = matches.filter {
                                if config.standaloneObservations {
                                    return targets.safePoint(for: $0) != nil
                                }
                                return layout.touchPoint($0) != nil
                            }""",
        "PokiCore select reachable continuous-path targets",
    )
    replace_once(
        routines,
        """                        let there = elements.filter { name.matches($0) && layout.touchPoint($0) != nil && Self.tappable.contains($0.type) }""",
        """                        guard let targets = lastTargets else { break attempts }
                        let there = elements.filter {
                            name.matches($0) && Self.tappable.contains($0.type) &&
                                (config.standaloneObservations ? targets.safePoint(for: $0) != nil : layout.touchPoint($0) != nil)
                        }""",
        "PokiCore select reachable continuous-path dismissal controls",
    )
    replace_once(
        routines,
        """                            let (pick, reason) = Self.pick(among: reachable, for: target)""",
        """                            let ambiguous = !target.hasPlace && matches.filter { Self.tappable.contains($0.type) }.count > 1
                            let (pick, reason) = Self.pick(among: ambiguous ? matches : reachable, for: target)""",
        "PokiCore keep repeated path targets ambiguous when one is covered",
    )
    replace_once(
        routines,
        '                    let tap: JSON = ["tap": .number(Double(Self.runRef))]',
        '''                    if config.standaloneObservations, let point = lastTargets?.safePoint(for: element) {
                        verifiedTargets[Self.runRef] = (element, point)
                    }
                    let tap: JSON = ["tap": .number(Double(Self.runRef))]''',
        "PokiCore dispatch the checked dismissal point",
    )
    replace_once(
        routines,
        "                    refs[Self.runRef] = nil\n                    closedHere += 1",
        """                    refs[Self.runRef] = nil
                    verifiedTargets[Self.runRef] = nil
                    closedHere += 1""",
        "PokiCore clear the checked dismissal point",
    )
    replace_once(
        routines,
        "                                if here == candidate || now() - attemptStart > 1.5 { found = pick; break }",
        """                                if here == candidate || now() - attemptStart > 1.5 {
                                    found = pick
                                    if config.standaloneObservations { foundPoint = targets.safePoint(for: pick) }
                                    break
                                }""",
        "PokiCore retain the selected target's safe point",
    )
    replace_once(
        routines,
        "                refs[Self.runRef] = element\n                action = Self.replacingTarget(action, with: Self.runRef)",
        """                refs[Self.runRef] = element
                if let foundPoint { verifiedTargets[Self.runRef] = (element, foundPoint) }
                action = Self.replacingTarget(action, with: Self.runRef)""",
        "PokiCore dispatch the selected target's safe point",
    )
