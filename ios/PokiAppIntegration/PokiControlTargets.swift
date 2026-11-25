import Foundation

/// Screen coordinates locate a control, but do not identify it. Reused list
/// cells can keep the same button and frame when a different row moves into them.
struct PokiControlTargets {
    private enum TouchPoint {
        case available(x: Double, y: Double)
        case covered
    }

    private final class ReachabilityCache {
        var points: [Int: TouchPoint] = [:]
        var grids: [Int: MirroredGridEvidence?] = [:]
    }

    private static let rowTypes: Set<String> = ["Cell", "Row", "TableRow", "OutlineRow"]
    private static let wrapperTypes: Set<String> = ["Group", "Other"]
    private static let titleTypes: Set<String> = ["StaticText", "Heading", "Link"]
    private static let chromeTypes = Layout.bars.union(["SearchBar", "MenuBar"])
    private static let fieldTypes: Set<String> = ["SearchField", "TextField", "SecureTextField", "TextView"]
    private static let actionTypes = fieldTypes.union([
        "Button", "Link", "Switch", "Toggle", "CheckBox", "RadioButton", "Slider", "Stepper",
        "PickerWheel", "ComboBox", "PopUpButton", "MenuButton",
    ])

    private let all: [Element]
    private let viewport: Rect
    private let screen: ScreenSize
    private let scrollers: [Element]
    private let rows: [Element]
    private let wrappers: [Element]
    private let chrome: [Element]
    private let keyboards: [Element]
    private let named: [String: [Element]]
    private let searchIdentity: PokiSearchFieldIdentity
    private let reachability = ReachabilityCache()

    init(_ elements: [Element], screen: ScreenSize) {
        all = elements
        self.screen = screen
        viewport = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        let scrollers = elements.filter { Layout.scrollers.contains($0.type) }
        let rows = elements.filter { Self.rowTypes.contains($0.type) }
        let wrappers = elements.filter { Self.wrapperTypes.contains($0.type) && $0.frame.height <= screen.height * 0.35 }
        let chrome = elements.filter { Self.chromeTypes.contains($0.type) }
        self.scrollers = scrollers
        self.rows = rows
        self.wrappers = wrappers
        self.chrome = chrome
        keyboards = elements.filter { $0.type == "Keyboard" }
        let visible = elements.filter { !$0.fromPicture && !$0.text.isEmpty }
        named = Dictionary(grouping: visible, by: Self.key)
        searchIdentity = PokiSearchFieldIdentity(all: elements, scrollers: scrollers, rows: rows,
                                                 wrappers: wrappers, chrome: chrome)
    }

    func visibleFrame(_ element: Element) -> Rect {
        var frame = element.frame.intersection(viewport)
        for scroller in scrollers where scroller.contains(element) {
            frame = frame.intersection(scroller.frame)
        }
        return frame
    }

    private func matches(_ element: Element) -> [Element] {
        let visible = (named[Self.key(element)] ?? []).filter { !visibleFrame($0).isEmpty }
        guard visible.count > 1 else { return visible }
        var seen = Set<String>()
        return visible.filter { candidate in
            guard let parent = parent(of: candidate) else { return true }
            return seen.insert("\(parent.node)|\(candidate.identifier ?? "")|\(candidate.frame.described)").inserted
        }
    }

    private static func key(_ element: Element) -> String {
        // A search field's typed query can change while its accessibility label stays put.
        if fieldTypes.contains(element.type), let label = element.label, !label.isEmpty {
            return "\(element.type)|\(label)"
        }
        // Some apps expose a search input as text with a rotating suggested query.
        if element.type == "StaticText", let label = element.label,
           let prefix = ["搜索框，输入文字", "搜尋框，輸入文字"].first(where: label.hasPrefix) {
            return "\(element.type)|\(prefix)"
        }
        return element.key
    }

    private static func sameIdentifier(_ earlier: Element, _ current: Element) -> Bool {
        if earlier.identifier == current.identifier { return true }
        // XCTest can expose the changing search suggestion itself as the name.
        guard earlier.type == "StaticText", earlier.label != current.label,
              key(earlier) == key(current),
              earlier.identifier == earlier.label, current.identifier == current.label else { return false }
        return ["搜索框，输入文字", "搜尋框，輸入文字"].contains { earlier.label?.hasPrefix($0) == true }
    }

    private func bar(for element: Element) -> Element? {
        chrome.last { $0.contains(element) }
    }

    private func parent(of element: Element) -> Element? {
        all.last { $0.depth + 1 == element.depth && $0.contains(element) }
    }

    private func searchFieldMirrors(_ element: Element) -> PokiSearchFieldIdentity.Mirrors? {
        searchIdentity.mirrors(element, candidates: named[Self.key(element)] ?? [],
                               visibleFrame: visibleFrame, parent: parent)
    }

    private func row(for element: Element) -> Element? {
        guard bar(for: element) == nil else { return nil }
        if let row = rows.last(where: { $0.contains(element) && $0.frame.contains(element.frame.centre) }) {
            return row
        }
        guard element.type != "SearchField", let list = scrollers.last(where: { $0.contains(element) }) else { return nil }
        let peers = matches(element).filter { $0.node != element.node && list.contains($0) }
        guard !peers.isEmpty else { return nil }
        // Custom lists may use generic groups instead of cells. A single
        // compact group can also be a header: look for repeated item structure.
        return wrappers.reversed().first { row in
            guard list.contains(row), row.contains(element), row.frame.contains(element.frame.centre),
                  !peers.contains(where: row.contains),
                  let parent = parent(of: row) else { return false }
            return wrappers.contains { peerRow in
                peerRow.depth == row.depth && parent.contains(peerRow) &&
                    !peerRow.frame.intersects(row.frame) && peers.contains(where: peerRow.contains)
            }
        }
    }

    private func rowTitles(_ element: Element) -> [String] {
        guard let row = row(for: element) else { return [] }
        return rowTitles(element, in: row)
    }

    private func rowTitles(_ element: Element, in row: Element) -> [String] {
        let labels = [row.label] + all.lazy.filter {
            $0.node != element.node && row.contains($0) && !element.contains($0) &&
                Self.titleTypes.contains($0.type) && row.frame.intersects($0.frame)
        }.prefix(8).map(\.label)
        return labels.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != element.label }
    }

    private func distinctRowTitle(_ element: Element, peers: [Element]) -> String? {
        let otherTitles = Set(peers.filter { $0.node != element.node }.flatMap(rowTitles))
        return rowTitles(element).first { !otherTitles.contains($0) }
    }

    private static func branchCardTitle(_ label: String?) -> String? {
        guard let label, let separator = label.firstIndex(where: { "，,\n".contains($0) }) else { return nil }
        let title = String(label[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...80).contains(title.count), let last = title.last,
              let opening = title.lastIndex(of: last == ")" ? "(" : "（"),
              (last == ")" || last == "）"), opening != title.startIndex,
              title.index(after: opening) < title.index(before: title.endIndex) else { return nil }
        return title
    }

    private func uniqueBranchCardTitle(_ element: Element, in row: Element) -> String? {
        guard element.type == "Other", row.contains(element), let title = Self.branchCardTitle(element.label)
        else { return nil }
        for candidate in all where !candidate.fromPicture {
            guard candidate.node != element.node, !candidate.contains(element), !element.contains(candidate),
                  candidate.label == title || Self.branchCardTitle(candidate.label) == title,
                  !visibleFrame(candidate).isEmpty else { continue }
            if let candidateRow = self.row(for: candidate), candidateRow.node == row.node,
               !Self.wrapperTypes.contains(candidate.type), !Self.actionTypes.contains(candidate.type) {
                continue
            }
            return nil
        }
        return title
    }

    private func mainRowTitle(_ element: Element) -> String? {
        guard let row = row(for: element) else { return nil }
        let label = row.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstText = all.filter {
            $0.node != element.node && row.contains($0) && !element.contains($0) &&
                Self.titleTypes.contains($0.type) && !$0.fromPicture && row.frame.intersects($0.frame) &&
                !($0.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.min {
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            return $0.frame.x < $1.frame.x
        }?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = label?.isEmpty == false && label != element.label ? label : firstText
        guard let title, (2...60).contains(title.count), !title.contains("\n"),
              title.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
        let metadataPrefixes = ["¥", "￥", "$", "月售", "已售", "销量", "配送", "起送", "评分", "券", "红包",
                                "优惠", "限时", "立减", "秒杀", "折扣", "到手价", "预估", "招牌", "新品",
                                "热销", "推荐", "人气", "本店", "免配送", "售罄"]
        guard !metadataPrefixes.contains(where: title.hasPrefix) else { return nil }
        return title
    }

    private struct GridNeighbor: Hashable {
        let name: String
        let isRight: Bool
    }

    private func gridNeighbors(_ element: Element, in row: Element) -> Set<GridNeighbor> {
        let frame = visibleFrame(element)
        guard !frame.isEmpty, frame.width <= viewport.width / 2, let scope = parent(of: row) else { return [] }
        let requiredPeers = row.frame.width > viewport.width / 2 ? 2 : 1
        var neighbors = Set<GridNeighbor>()
        for peer in all {
            guard peer.node != element.node, peer.type == element.type, scope.contains(peer),
                  !peer.fromPicture, !peer.text.isEmpty, Self.key(peer) != Self.key(element)
            else { continue }
            let other = visibleFrame(peer)
            guard !other.isEmpty, !frame.intersects(other),
                  other.width >= frame.width / 2, other.width <= frame.width * 2,
                  other.height >= frame.height / 2, other.height <= frame.height * 2,
                  abs(frame.centre.y - other.centre.y) <= min(frame.height, other.height) / 4 else { continue }
            let gap = max(frame.x, other.x) - min(frame.maxX, other.maxX)
            guard gap <= max(frame.width, other.width) * 2,
                  let peerRow = self.row(for: peer), peerRow.node == row.node || parent(of: peerRow)?.node == scope.node
            else { continue }
            neighbors.insert(GridNeighbor(name: Self.key(peer), isRight: other.x >= frame.maxX))
        }
        return neighbors.count >= requiredPeers ? neighbors : []
    }

    private struct MirroredGridEvidence {
        let copies: Int
        let aligned: Bool
        let scopes: Int
        let minNeighbors: Int
        let common: Set<GridNeighbor>

        var confirmed: Bool { aligned && scopes == copies && common.count >= 2 }
        var diagnostic: String {
            " [grid copies=\(copies) aligned=\(aligned ? 1 : 0) scopes=\(scopes) neighbors=\(minNeighbors) common=\(common.count)]"
        }
    }

    private func mirroredGridNeighbors(_ element: Element, in scope: Element) -> Set<GridNeighbor>? {
        var neighbors = Set<GridNeighbor>()
        var positions: [String: Rect] = [:]
        for peer in all where peer.type == "Cell" && !peer.fromPicture && scope.contains(peer) {
            guard peer.node != element.node, Self.key(peer) != Self.key(element),
                  !peer.text.isEmpty, peer.text.count <= 32 else { continue }
            let frame = visibleFrame(peer)
            guard !frame.isEmpty, !frame.intersects(element.frame),
                  frame.width >= element.frame.width / 2, frame.width <= element.frame.width * 2,
                  frame.height >= element.frame.height / 2, frame.height <= element.frame.height * 2,
                  abs(frame.centre.y - element.frame.centre.y) <= min(frame.height, element.frame.height) / 4
            else { continue }
            let gap = max(element.frame.x, frame.x) - min(element.frame.maxX, frame.maxX)
            guard gap <= max(element.frame.width, frame.width) * 2 else { continue }
            let key = Self.key(peer)
            if let previous = positions[key], previous != frame { return nil }
            positions[key] = frame
            neighbors.insert(GridNeighbor(name: key, isRight: frame.x >= element.frame.maxX))
        }
        return neighbors
    }

    private func mirroredGridEvidence(_ element: Element) -> MirroredGridEvidence? {
        if let cached = reachability.grids[element.node] { return cached }
        let result = calculateMirroredGridEvidence(element)
        reachability.grids.updateValue(result, forKey: element.node)
        if result?.aligned == true {
            for copy in matches(element) {
                reachability.grids.updateValue(result, forKey: copy.node)
            }
        }
        return result
    }

    private func calculateMirroredGridEvidence(_ element: Element) -> MirroredGridEvidence? {
        guard element.type == "Cell", !element.fromPicture,
              !element.text.isEmpty, element.text.count <= 32,
              element.frame.width > 16, element.frame.width <= viewport.width / 3,
              element.frame.height <= element.frame.width * 2 else { return nil }
        let copies = matches(element)
        guard copies.count > 1 else { return nil }
        let aligned = copies.allSatisfy({
            $0.frame == element.frame && $0.identifier == element.identifier
        })
        var common: Set<GridNeighbor>?
        var scopes = 0
        var minNeighbors = Int.max
        for copy in copies {
            // Each mirror needs its own neighbors: an unrelated overlaid page
            // must not provide evidence for another branch's control.
            var scope = parent(of: copy)
            var best = 0
            var found: Set<GridNeighbor>?
            while let candidate = scope,
                  !copies.contains(where: { $0.node != copy.node && candidate.contains($0) }) {
                if let neighbors = mirroredGridNeighbors(copy, in: candidate) {
                    best = max(best, neighbors.count)
                    if neighbors.count >= 2 { found = neighbors; break }
                }
                scope = parent(of: candidate)
            }
            minNeighbors = min(minNeighbors, best)
            guard let neighbors = found else { continue }
            scopes += 1
            if let existing = common {
                common = existing.intersection(neighbors)
            } else {
                common = neighbors
            }
        }
        return MirroredGridEvidence(copies: copies.count, aligned: aligned, scopes: scopes,
                                    minNeighbors: minNeighbors, common: common ?? [])
    }

    private enum PageAnchor: Equatable {
        case identifier(String)
        case bar(type: String, label: String?)
        case outsideKeyboard
    }

    private func pageAnchors(_ element: Element, peers: [Element]) -> [PageAnchor] {
        let others = peers.filter { $0.node != element.node }
        var anchors: [PageAnchor] = []
        if let identifier = element.identifier, !identifier.isEmpty, identifier != element.label,
           !others.contains(where: { $0.identifier == identifier }) {
            anchors.append(.identifier(identifier))
        }
        if let bar = bar(for: element), !others.contains(where: {
            self.bar(for: $0).map { $0.type == bar.type && $0.label == bar.label } == true
        }) {
            anchors.append(.bar(type: bar.type, label: bar.label))
        }
        let isKeyboardControl: (Element) -> Bool = { item in
            self.keyboards.contains { $0.contains(item) }
        }
        if !isKeyboardControl(element), !others.contains(where: { !isKeyboardControl($0) }) {
            anchors.append(.outsideKeyboard)
        }
        return anchors
    }

    func annotation(for element: Element) -> String {
        guard !element.fromPicture else { return "" }
        if searchFieldMirrors(element) != nil { return "" }
        if Computer.containers.contains(element.type) {
            guard element.type == "Other", row(for: element) != nil else { return "" }
        }
        if (named[Self.key(element)]?.count ?? 0) <= 1 {
            return uniqueRowAnnotation(for: element)
        }
        let peers = matches(element)
        guard peers.count > 1 else { return uniqueRowAnnotation(for: element) }
        let grid = mirroredGridEvidence(element)
        if grid?.confirmed == true { return "" }
        if row(for: element) == nil, !pageAnchors(element, peers: peers).isEmpty { return "" }
        guard let title = distinctRowTitle(element, peers: peers) else {
            return (grid?.diagnostic ?? "") + " [row unverified]"
        }
        let singleLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return " [row: \(singleLine.prefix(60))]"
    }

    private func uniqueRowAnnotation(for element: Element) -> String {
        guard Self.actionTypes.contains(element.type), !rows.isEmpty,
              let row = row(for: element), rowTitles(element, in: row).isEmpty else { return "" }
        return gridNeighbors(element, in: row).isEmpty ? " [row unverified]" : ""
    }

    // The execution path still uses the observed coordinate. Verify that exact
    // point in the current visible frame instead of requiring equal frame centres.
    func control(matching previous: Element, at point: (x: Double, y: Double)) -> Element? {
        let candidates = matches(previous).filter {
            Self.sameIdentifier(previous, $0) && containsTouch(point, in: $0)
        }
        if candidates.count > 1, let first = candidates.first, mirroredGridEvidence(first)?.confirmed == true {
            return first
        }
        if candidates.count > 1, let first = candidates.first, searchFieldMirrors(first) != nil {
            return first
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    fileprivate func identityCounts(for previous: Element, on earlier: PokiControlTargets,
                                    at point: (x: Double, y: Double)) -> String {
        let candidates = matches(previous)
        let sameIdentifier = candidates.filter { Self.sameIdentifier(previous, $0) }
        let atPoint = sameIdentifier.filter { containsTouch(point, in: $0) }
        return "[identity counts: previous=\(earlier.matches(previous).count), current=\(candidates.count), " +
            "same_identifier=\(sameIdentifier.count), at_point=\(atPoint.count)]"
    }

    func containsTouch(_ point: (x: Double, y: Double), in element: Element) -> Bool {
        let frame = visibleFrame(element)
        return frame.x <= point.x && point.x < frame.maxX && frame.y <= point.y && point.y < frame.maxY
    }

    func coversTouch(_ cover: Element, over target: Element, at point: (x: Double, y: Double)) -> Bool {
        guard containsTouch(point, in: cover) else { return false }
        if let parent = parent(of: target), parent == self.parent(of: cover) {
            if Self.key(cover) == Self.key(target), cover.identifier == target.identifier,
               cover.frame.described == target.frame.described { return false }
            // A native control and the text it draws can be siblings in the AX tree.
            if cover.type == "StaticText", let label = target.label, cover.text == label,
               target.frame.intersection(cover.frame) == cover.frame { return false }
        }
        return true
    }

    fileprivate func blockedByOverlay(_ element: Element) -> Bool {
        let targets = searchFieldMirrors(element)?.copies ?? [element]
        return all.contains(where: {
            let overlay = $0
            return (overlay.type == "Alert" || overlay.type == "Sheet") && targets.contains {
                !overlay.contains($0) && overlay.frame.intersects(visibleFrame($0))
            }
        })
    }

    fileprivate func coveringControls(for element: Element) -> [Element] {
        var mirrors = [element]
        if mirroredGridEvidence(element)?.confirmed == true {
            mirrors = matches(element)
        } else if let search = searchFieldMirrors(element) {
            mirrors = search.copies
        }
        let layout = Layout(all: all, screen: screen)
        let outside = mirrors.flatMap { layout.covers($0) }.filter { cover in
            !mirrors.contains { $0.node == cover.node }
        }
        let inside = all.filter {
            let child = $0
            return mirrors.contains { $0.contains(child) } && Self.actionTypes.contains(child.type) &&
                child.frame.intersects(element.frame)
        }
        let otherActions = mirrors.count > 1 && element.type == "SearchField" ? all.filter { candidate in
            Self.actionTypes.contains(candidate.type) && !mirrors.contains(where: { $0.node == candidate.node }) &&
                mirrors.contains { candidate.frame.intersects($0.frame) && !candidate.contains($0) }
        } : []
        return (outside + inside + otherActions).filter { cover in !mirrors.contains { $0.node == cover.node } }
    }

    fileprivate func isSafePoint(_ point: (x: Double, y: Double), for element: Element,
                                 frame: Rect, covers: [Element]) -> Bool {
        let contact = Rect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        guard frame.x <= contact.x, frame.y <= contact.y,
              contact.maxX < frame.maxX, contact.maxY < frame.maxY else { return false }
        for cover in covers {
            let overlap = contact.intersection(visibleFrame(cover))
            if !overlap.isEmpty && coversTouch(cover, over: element, at: overlap.centre) { return false }
        }
        return true
    }

    func canTouch(_ point: (x: Double, y: Double), on element: Element) -> Bool {
        !blockedByOverlay(element) && isSafePoint(point, for: element, frame: visibleFrame(element),
                                                  covers: coveringControls(for: element))
    }

    /// A touch is only safe when the contact and normal input scatter fit in the visible area.
    func safePoint(for element: Element) -> (x: Double, y: Double)? {
        if let cached = reachability.points[element.node] {
            switch cached {
            case .available(let x, let y): return (x, y)
            case .covered: return nil
            }
        }
        let point = findSafePoint(for: element)
        reachability.points[element.node] = point.map { .available(x: $0.x, y: $0.y) } ?? .covered
        return point
    }

    private func findSafePoint(for element: Element) -> (x: Double, y: Double)? {
        let frame = visibleFrame(element)
        guard frame.width > 8, frame.height > 8, !blockedByOverlay(element) else { return nil }
        let covers = coveringControls(for: element)
        let centre = frame.centre
        if isSafePoint(centre, for: element, frame: frame, covers: covers) { return centre }
        var best: (point: (x: Double, y: Double), distance: Double)?
        for x in 0..<9 {
            for y in 0..<9 {
                let point = (x: frame.x + frame.width * (Double(x) + 0.5) / 9,
                             y: frame.y + frame.height * (Double(y) + 0.5) / 9)
                guard isSafePoint(point, for: element, frame: frame, covers: covers) else { continue }
                let distance = hypot(point.x - centre.x, point.y - centre.y)
                if best == nil || distance < best!.distance { best = (point, distance) }
            }
        }
        return best?.point
    }

    func reachabilityAnnotation(for element: Element, listed: [(ref: Int, element: Element)]) -> String {
        guard !element.fromPicture,
              Self.actionTypes.contains(element.type) || ["Other", "Group", "Cell", "Row"].contains(element.type),
              !element.text.isEmpty, !visibleFrame(element).isEmpty else { return "" }
        let covered = safePoint(for: element) == nil
        var children: [String] = []
        if element.end > element.node {
            children = listed.lazy.filter {
                element.contains($0.element) && Self.actionTypes.contains($0.element.type) &&
                    safePoint(for: $0.element) != nil
            }.prefix(4).map { String($0.ref) }
        }
        let coverTag = covered ? " [covered]" : ""
        let childTag = children.isEmpty ? "" : " [children: \(children.joined(separator: ", "))]"
        return coverTag + childTag
    }

    /// Match a small movement only when both reads identify one control and it keeps its row identity.
    func relocatedControl(matching previous: Element, on earlier: PokiControlTargets) -> Element? {
        let old = earlier.matches(previous)
        let candidates = matches(previous).filter { Self.sameIdentifier(previous, $0) }
        guard old.count == 1, candidates.count == 1, let live = candidates.first else { return nil }
        let dx = abs(live.frame.centre.x - previous.frame.centre.x)
        let dy = abs(live.frame.centre.y - previous.frame.centre.y)
        let widthChange = abs(live.frame.width - previous.frame.width)
        let heightChange = abs(live.frame.height - previous.frame.height)
        guard dx + dy > 0, dx <= min(20, previous.frame.width / 4), dy <= min(20, previous.frame.height / 4),
              widthChange <= max(4, previous.frame.width / 4), heightChange <= max(4, previous.frame.height / 4),
              earlier.identityProblem(for: previous, matching: live, on: self) == nil else { return nil }
        return live
    }

    /// A named list item can move when content above it loads or the list reorders.
    func relocatedRowControl(matching previous: Element, on earlier: PokiControlTargets) -> Element? {
        let earlierPeers = earlier.matches(previous)
        guard let title = earlier.mainRowTitle(previous),
              earlierPeers.filter({ earlier.mainRowTitle($0) == title }).count == 1 else { return nil }
        let candidates = matches(previous).filter { candidate in
            Self.sameIdentifier(previous, candidate) && mainRowTitle(candidate) == title
        }
        guard candidates.count == 1, let live = candidates.first,
              earlier.identityProblem(for: previous, matching: live, on: self) == nil else { return nil }
        return live
    }

    func identityProblem(for previous: Element, matching target: Element, on current: PokiControlTargets) -> String? {
        let previousPeers = matches(previous)
        let livePeers = current.matches(target)
        let oldSearch = searchFieldMirrors(previous)
        let liveSearch = current.searchFieldMirrors(target)
        if oldSearch != nil || liveSearch != nil {
            guard let oldSearch, let liveSearch,
                  PokiSearchFieldIdentity.matches(previous, oldSearch, target, liveSearch) else {
                return "the search field or its page could not be confirmed"
            }
            return nil
        }
        if let before = mirroredGridEvidence(previous), let after = current.mirroredGridEvidence(target),
           before.confirmed, after.confirmed, before.common.intersection(after.common).count >= 2 {
            return nil
        }
        let previousRow = row(for: previous)
        let liveRow = current.row(for: target)
        if previous.type == "StaticText", previous.label != target.label,
           Self.key(previous) == Self.key(target), (previousPeers.count != 1 || livePeers.count != 1) {
            return "it could not be distinguished from other search controls"
        }
        if previousRow != nil || liveRow != nil {
            // Some list cards expose the branch and all metadata as one control.
            if let previousRow, let liveRow, previous.label == target.label,
               let title = uniqueBranchCardTitle(previous, in: previousRow),
               current.uniqueBranchCardTitle(target, in: liveRow) == title {
                return nil
            }
            // A grid tile may be exposed as a cell whose only identity is the
            // control's own label. A named neighbor anchors the same grid in both reads.
            if let previousRow, let liveRow, previousPeers.count == 1, livePeers.count == 1,
               rowTitles(previous, in: previousRow).isEmpty, current.rowTitles(target, in: liveRow).isEmpty {
                let neighbors = gridNeighbors(previous, in: previousRow)
                let liveNeighbors = current.gridNeighbors(target, in: liveRow)
                if !neighbors.isDisjoint(with: liveNeighbors) { return nil }
            }
            if let title = distinctRowTitle(previous, peers: previousPeers),
               current.rowTitles(target).contains(title),
               !livePeers.contains(where: { $0.node != target.node && current.rowTitles($0).contains(title) }) {
                return nil
            }
            return "its list row could not be confirmed"
        }
        if previousPeers.count > 1 || livePeers.count > 1 {
            let currentAnchors = current.pageAnchors(target, peers: livePeers)
            if !pageAnchors(previous, peers: previousPeers).contains(where: currentAnchors.contains) {
                return "it could not be distinguished from other controls with the same name"
            }
        }
        return nil
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
        for target in targets {
            guard let intended = previous.safePoint(for: target.element) else {
                return "control \(target.ref) is covered at its recorded touch point. Choose it again on the fresh screen below"
            }
            let atPoint = current.control(matching: target.element, at: intended)
            let problem = atPoint.flatMap { previous.identityProblem(for: target.element, matching: $0, on: current) }
            let positioned = problem == nil ? atPoint : nil
            let relocated = positioned == nil
                ? current.relocatedControl(matching: target.element, on: previous) ??
                    current.relocatedRowControl(matching: target.element, on: previous)
                : nil
            guard let live = positioned ?? relocated else {
                let counts = current.identityCounts(for: target.element, on: previous, at: intended)
                if let problem {
                    return "control \(target.ref) was not tapped: \(problem). \(counts) Choose it again on the fresh screen below"
                }
                return "control \(target.ref) changed or is no longer at its recorded position. \(counts) Choose it again on the fresh screen below"
            }
            let covers = current.coveringControls(for: live)
            if current.blockedByOverlay(live) {
                return "control \(target.ref) is covered at its recorded touch point. Choose it again on the fresh screen below"
            }
            let point: (x: Double, y: Double)?
            if current.isSafePoint(intended, for: live, frame: current.visibleFrame(live), covers: covers) {
                point = intended
            } else if relocated != nil || current.relocatedControl(matching: target.element, on: previous) == live {
                point = current.safePoint(for: live)
            } else {
                point = nil
            }
            guard let point else {
                return "control \(target.ref) is covered at its recorded touch point. Choose it again on the fresh screen below"
            }
            verifiedTargets[target.ref] = (live, point)
        }
        return nil
    }
}
