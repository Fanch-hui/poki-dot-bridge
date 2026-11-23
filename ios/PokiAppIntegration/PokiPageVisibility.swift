import Foundation

/// Two page-sized branches can share the same accessibility snapshot even when
/// only one of them is drawn. Check the screenshot only for that shape of tree.
struct PokiPageVisibility {
    private static let pageTypes: Set<String> = [
        "Window", "Other", "Group", "ScrollView", "WebView", "CollectionView", "Table",
    ]
    private static let anchorTypes: Set<String> = [
        "StaticText", "Button", "Cell", "Link", "TextField", "TextView", "Tab",
    ]

    private struct Competition {
        let front: Int
        let covered: Int
        let overlap: Rect
    }

    private struct Anchor {
        let text: String
        let frame: Rect
    }

    private let screen: ScreenSize
    private let competitions: [Competition]
    private let anchors: [Int: [Anchor]]
    private let pages: [Element]

    init?(elements: [Element], screen: ScreenSize) {
        // Preserve the native tree for system modals and secure input.
        guard !elements.contains(where: { $0.isSecure || $0.type == "Alert" || $0.type == "Sheet" }) else { return nil }
        let viewport = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        let pages = elements.filter {
            guard $0.end > $0.node, Self.pageTypes.contains($0.type) else { return false }
            let frame = $0.frame.intersection(viewport)
            return frame.width >= screen.width * 0.75 && frame.height >= screen.height * 0.5
        }
        let frames = pages.map { $0.frame.intersection(viewport) }
        var competitions: [Competition] = []
        for first in pages.indices {
            // A wrapper and its own content describe one page, not two.
            for second in pages.indices.dropFirst(first + 1) where !pages[first].contains(pages[second]) {
                let overlap = frames[first].intersection(frames[second])
                if overlap.area >= frames[second].area * 0.92 {
                    competitions.append(Competition(front: first, covered: second, overlap: overlap))
                }
                if overlap.area >= frames[first].area * 0.92 {
                    competitions.append(Competition(front: second, covered: first, overlap: overlap))
                }
            }
        }
        guard !competitions.isEmpty else { return nil }
        var anchors: [Int: [Anchor]] = [:]
        for index in Set(competitions.flatMap { [$0.front, $0.covered] }) {
            anchors[index] = elements.filter { pages[index].contains($0) }.flatMap {
                Self.textAnchors($0, viewport: viewport)
            }
        }
        competitions = competitions.filter {
            Set((anchors[$0.front] ?? []).map(\.text)).count >= 2 &&
                Set((anchors[$0.covered] ?? []).map(\.text)).count >= 2
        }
        guard !competitions.isEmpty else { return nil }
        self.screen = screen
        self.competitions = competitions
        self.anchors = anchors
        self.pages = pages
    }

    private static func textAnchors(_ element: Element, viewport: Rect) -> [Anchor] {
        guard anchorTypes.contains(element.type) else { return [] }
        let frame = element.frame.intersection(viewport)
        guard !frame.isEmpty else { return [] }
        return [element.label, element.value].compactMap { label in
            guard let label, let text = normalized(label) else { return nil }
            return Anchor(text: text, frame: frame)
        }
    }

    private static func normalized(_ label: String) -> String? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (2...48).contains(text.count), text.contains(where: \.isLetter) else { return nil }
        return text
    }

    func filter(_ elements: [Element], using texts: [RecognizedText]) -> [Element]? {
        var picturePoints: [String: [(x: Double, y: Double)]] = [:]
        for item in texts {
            guard let text = Self.normalized(item.text) else { continue }
            picturePoints[text, default: []].append((item.box.centre.x * screen.width, item.box.centre.y * screen.height))
        }
        let matches = anchors.mapValues { anchors in
            anchors.flatMap { anchor in
                (picturePoints[anchor.text] ?? []).filter(anchor.frame.contains).map { (anchor.text, $0) }
            }
        }
        let covered = Set(competitions.compactMap { pair -> Int? in
            guard let foreground = matches[pair.front], let background = matches[pair.covered],
                  background.isEmpty, let coveredAnchors = anchors[pair.covered] else { return nil }
            // Require distinct text in the shared area, including a position the
            // accessibility tree attributes to different text on the other page.
            let witnessed = foreground.filter { pair.overlap.contains($0.1) }
            guard Set(witnessed.map { $0.0 }).count >= 2, witnessed.contains(where: { match in
                coveredAnchors.contains { $0.text != match.0 && $0.frame.contains(match.1) }
            }) else { return nil }
            return pair.covered
        })
        guard !covered.isEmpty else { return nil }
        let supported = matches.keys.filter { matches[$0]?.isEmpty == false }.map { pages[$0] }
        let hidden = covered.map { pages[$0] }.filter { page in !supported.contains(where: page.contains) }
        guard !hidden.isEmpty else { return nil }
        return elements.filter { element in
            !hidden.contains { $0.node == element.node || $0.contains(element) }
        }
    }
}
