import Foundation

/// Confirms mirrored search fields only with a shared control structure and page header.
final class PokiSearchFieldIdentity {
    fileprivate struct PageAnchor: Hashable {
        let type: String
        let label: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    fileprivate struct Scope: Equatable {
        let type: String
        let label: String?
        let identifier: String?
        let frame: String?
    }

    struct Mirrors {
        let copies: [Element]
        fileprivate let scope: Scope
        fileprivate let anchors: Set<PageAnchor>
    }

    private let all: [Element]
    private let scrollers: [Element]
    private let rows: [Element]
    private let wrappers: [Element]
    private let chrome: [Element]
    private var cache: [Int: Mirrors?] = [:]

    init(all: [Element], scrollers: [Element], rows: [Element], wrappers: [Element], chrome: [Element]) {
        self.all = all
        self.scrollers = scrollers
        self.rows = rows
        self.wrappers = wrappers
        self.chrome = chrome
    }

    func mirrors(_ element: Element, candidates: [Element], visibleFrame: (Element) -> Rect,
                 parent: (Element) -> Element?) -> Mirrors? {
        guard element.type == "SearchField" else { return nil }
        if let cached = cache[element.node] { return cached }
        let found = findMirrors(element, candidates: candidates, visibleFrame: visibleFrame, parent: parent)
        cache.updateValue(found, forKey: element.node)
        if let found {
            for copy in found.copies { cache.updateValue(found, forKey: copy.node) }
        }
        return found
    }

    static func matches(_ previous: Element, _ before: Mirrors, _ target: Element, _ after: Mirrors) -> Bool {
        before.scope == after.scope && before.copies.count == after.copies.count &&
            previous.type == target.type && previous.label == target.label && previous.value == target.value &&
            previous.identifier == target.identifier && previous.frame.described == target.frame.described &&
            hasHeader(before.anchors.intersection(after.anchors))
    }

    private func pageAnchors(above field: Element, visibleFrame: (Element) -> Rect) -> Set<PageAnchor> {
        let anchors = Set(all.compactMap { element -> PageAnchor? in
            guard ["StaticText", "Heading"].contains(element.type), !element.fromPicture,
                  let label = element.label, (2...32).contains(label.count), label != field.label,
                  element.frame.y >= 40, element.frame.maxY <= field.frame.y,
                  field.frame.y - element.frame.maxY <= 120, !visibleFrame(element).isEmpty,
                  !rows.contains(where: { $0.contains(element) }) else { return nil }
            return PageAnchor(type: element.type, label: label,
                              x: Int(element.frame.x.rounded()), y: Int(element.frame.y.rounded()),
                              width: Int(element.frame.width.rounded()), height: Int(element.frame.height.rounded()))
        })
        return anchors.filter { anchor in anchors.filter { $0.label == anchor.label }.count == 1 }
    }

    private static func hasHeader(_ anchors: Set<PageAnchor>) -> Bool {
        anchors.contains { first in
            anchors.contains { second in
                guard first.label != second.label, first.height > 0, second.height > 0 else { return false }
                let overlap = min(first.y + first.height, second.y + second.height) - max(first.y, second.y)
                return overlap * 2 >= min(first.height, second.height) &&
                    (first.x + first.width <= second.x || second.x + second.width <= first.x)
            }
        }
    }

    private func inRepeatedListWrapper(_ element: Element, parent: (Element) -> Element?) -> Bool {
        for list in scrollers where list.contains(element) {
            for wrapper in wrappers where list.contains(wrapper) && wrapper.contains(element) {
                guard let parent = parent(wrapper) else { continue }
                if wrappers.contains(where: { peer in
                    peer.node != wrapper.node && peer.depth == wrapper.depth && parent.contains(peer) &&
                        !peer.frame.intersects(wrapper.frame) &&
                        peer.frame.width >= wrapper.frame.width * 0.8 &&
                        peer.frame.width <= wrapper.frame.width * 1.25 &&
                        peer.frame.height >= wrapper.frame.height * 0.5 &&
                        peer.frame.height <= wrapper.frame.height * 2
                }) { return true }
            }
        }
        return false
    }

    private func transparentPath(from ancestor: Element, to field: Element, copies: [Element]) -> Bool {
        all.filter { ancestor.contains($0) && $0.contains(field) }.allSatisfy { item in
            if copies.contains(where: { $0.node == item.node }) { return true }
            return ["Group", "Other"].contains(item.type) && item.text.isEmpty &&
                (item.identifier == nil || item.identifier == "")
        }
    }

    private func findMirrors(_ element: Element, candidates: [Element], visibleFrame: (Element) -> Rect,
                             parent: (Element) -> Element?) -> Mirrors? {
        guard let label = element.label, !label.isEmpty else { return nil }
        let copies = candidates.filter { !visibleFrame($0).isEmpty }
        let frame = visibleFrame(element)
        guard copies.count > 1, copies.contains(where: { $0.node == element.node }),
              copies.allSatisfy({ copy in
                  copy.label == label && copy.value == element.value && copy.identifier == element.identifier &&
                      copy.frame == element.frame && visibleFrame(copy) == frame &&
                      !rows.contains(where: { $0.contains(copy) }) && !inRepeatedListWrapper(copy, parent: parent)
              }) else { return nil }
        let anchors = pageAnchors(above: element, visibleFrame: visibleFrame)
        guard Self.hasHeader(anchors) else { return nil }
        if let bar = chrome.last(where: { $0.type == "SearchBar" && copies.allSatisfy($0.contains) }),
           copies.allSatisfy({ transparentPath(from: bar, to: $0, copies: copies) }) {
            let scope = Scope(type: bar.type, label: bar.label, identifier: bar.identifier, frame: bar.frame.described)
            return Mirrors(copies: copies, scope: scope, anchors: anchors)
        }
        let ordered = copies.sorted { $0.node < $1.node }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ first, second in
            first.contains(second) && transparentPath(from: first, to: second, copies: copies)
        }) else { return nil }
        return Mirrors(copies: copies, scope: Scope(type: "nested", label: nil, identifier: nil, frame: nil),
                       anchors: anchors)
    }
}
