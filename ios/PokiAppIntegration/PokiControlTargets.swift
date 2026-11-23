import Foundation

/// Screen coordinates locate a control, but do not identify it. Reused list
/// cells can keep the same button and frame when a different row moves into them.
struct PokiControlTargets {
    private static let rowTypes: Set<String> = ["Cell", "Group", "Other"]
    private static let titleTypes: Set<String> = ["StaticText", "Heading", "Link"]

    private let all: [Element]
    private let viewport: Rect
    private let scrollers: [Element]
    private let rowContainers: [Element]
    private let named: [String: [Element]]

    init(_ elements: [Element], screen: ScreenSize) {
        all = elements
        viewport = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        scrollers = elements.filter { Layout.scrollers.contains($0.type) }
        rowContainers = elements.filter { Self.rowTypes.contains($0.type) && $0.frame.height <= screen.height * 0.35 }
        let visible = elements.filter { !$0.fromPicture && !$0.text.isEmpty }
        named = Dictionary(grouping: visible, by: \.key)
    }

    func visibleFrame(_ element: Element) -> Rect {
        var frame = element.frame.intersection(viewport)
        for scroller in scrollers where scroller.contains(element) {
            frame = frame.intersection(scroller.frame)
        }
        return frame
    }

    private func matches(_ element: Element) -> [Element] {
        (named[element.key] ?? []).filter { !visibleFrame($0).isEmpty }
    }

    private func rowTitles(_ element: Element) -> [String] {
        for row in rowContainers.reversed() where row.contains(element) {
            guard row.frame.contains(element.frame.centre) else { continue }
            let siblings = all.filter { row.contains($0) && !$0.contains(element) }
            // A parent containing more than one of the same control is not a row.
            if siblings.contains(where: { $0.node != element.node && $0.key == element.key }) { break }
            let labels = [row.label] + siblings.lazy.filter {
                $0.node != element.node && !element.contains($0) && Self.titleTypes.contains($0.type) &&
                    row.frame.intersects($0.frame)
            }.prefix(8).map(\.label)
            let titles = labels.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != element.label }
            if !titles.isEmpty { return titles }
        }
        return []
    }

    private func distinctRowTitle(_ element: Element, peers: [Element]) -> String? {
        let otherTitles = Set(peers.filter { $0.node != element.node }.flatMap(rowTitles))
        return rowTitles(element).first { !otherTitles.contains($0) }
    }

    func annotation(for element: Element) -> String {
        guard !element.fromPicture, !Computer.containers.contains(element.type),
              (named[element.key]?.count ?? 0) > 1 else { return "" }
        let peers = matches(element)
        guard peers.count > 1 else { return "" }
        guard let title = distinctRowTitle(element, peers: peers) else { return " [row unverified]" }
        let singleLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return " [row: \(singleLine.prefix(60))]"
    }

    func confirmed(_ previous: Element, on current: PokiControlTargets) -> Element? {
        let live = current.matches(previous)
        let atOriginalFrame = live.filter {
            $0.identifier == previous.identifier && $0.frame.described == previous.frame.described
        }
        guard atOriginalFrame.count == 1, let target = atOriginalFrame.first else { return nil }
        let previousPeers = matches(previous)
        if previousPeers.count > 1 || live.count > 1 {
            guard let row = distinctRowTitle(previous, peers: previousPeers),
                  current.rowTitles(target).contains(row),
                  !live.contains(where: { $0.node != target.node && current.rowTitles($0).contains(row) }) else { return nil }
        } else if let row = rowTitles(previous).first, !current.rowTitles(target).contains(row) {
            return nil
        }
        return target
    }
}

extension Computer {
    /// Verify only references that are about to land a touch. Point-guided input
    /// and the existing recheck for screenshot-derived popup controls are separate.
    func targetsToVerify(_ action: JSON) -> [(ref: Int, element: Element)] {
        guard config.standaloneObservations, let kind = ActionKind(action) else { return [] }
        let specs: [JSON?]
        switch kind {
        case .tap, .longPress, .pinch: specs = [action[kind.rawValue]]
        case .type: specs = [action["ref"]]
        case .drag: specs = [action["drag"]?["from"], action["drag"]?["to"]]
        default: return []
        }
        return specs.compactMap { spec in
            guard let ref = spec?.int ?? spec?["ref"]?.int,
                  let element = refs[ref], !element.fromPicture else { return nil }
            return (ref, element)
        }
    }

    func controlProblem(_ targets: [(ref: Int, element: Element)], in fresh: [Element],
                        foreground: Foreground, screen: ScreenSize) -> String? {
        guard !targets.isEmpty else { return nil }
        guard let app = lastForeground?.bundleID, app == foreground.bundleID else {
            return "the foreground app changed or could not be confirmed. Choose a control from the fresh screen below"
        }
        let previous = PokiControlTargets(lastAll, screen: screen)
        let current = PokiControlTargets(fresh, screen: screen)
        let liveLayout = Layout(all: fresh, screen: screen)
        for target in targets {
            guard let live = previous.confirmed(target.element, on: current),
                  let intended = layout.touchPoint(target.element), let hit = liveLayout.touchPoint(live),
                  hit.free, current.visibleFrame(live).contains(intended.point),
                  abs(intended.point.x - hit.point.x) < 0.5, abs(intended.point.y - hit.point.y) < 0.5 else {
                return "control \(target.ref) could not be confirmed in the same row and position. Use the fresh screen below to choose the target again"
            }
        }
        return nil
    }
}
