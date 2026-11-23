import Foundation

/// A full-screen accessibility marker can name a custom popup while the tree still
/// contains the covered screen. Its later siblings are the popup's visible content.
struct PokiOverlay {
    let markerNode: Int
    let content: Rect?
    let screen: ScreenSize

    static func detect(in elements: [Element], screen: ScreenSize) -> PokiOverlay? {
        guard let marker = elements.last(where: { isPopupMarker($0, screen: screen) }) else { return nil }
        let foreground = elements.filter { $0.node > marker.node && !$0.fromPicture }
        guard !foreground.isEmpty else { return nil }
        let content = foreground
            .filter { element in
                let frame = element.frame
                return !element.text.isEmpty &&
                    frame.width >= screen.width * 0.4 && frame.width < screen.width * 0.95 &&
                    frame.height >= screen.height * 0.1 && frame.height < screen.height * 0.8
            }
            .max { $0.frame.area < $1.frame.area }?.frame
        return PokiOverlay(markerNode: marker.node, content: content, screen: screen)
    }

    private static func isPopupMarker(_ element: Element, screen: ScreenSize) -> Bool {
        guard !element.fromPicture, element.type == "Other" || element.type == "Window",
              element.frame.width >= screen.width * 0.85,
              element.frame.height >= screen.height * 0.85 else { return false }
        let text = element.text.lowercased()
        let popup = ["弹窗", "彈窗", "弹出窗口", "彈出視窗", "popup", "pop-up", "dialog", "modal"]
        let dismiss = ["退出", "关闭", "關閉", "dismiss", "close", "exit"]
        return popup.contains { text.contains($0) } && dismiss.contains { text.contains($0) }
    }

    func foreground(_ elements: [Element]) -> [Element] {
        elements.filter { !$0.fromPicture && $0.node >= markerNode }
    }

    /// Only name an OCR X as a dismiss control when its position agrees with the
    /// popup body. An arbitrary X in the dimmed page is not a reliable target.
    func closeControl(in texts: [RecognizedText]) -> Element? {
        guard let content else { return nil }
        let matches = texts.compactMap { text -> Rect? in
            let symbol = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["x", "X", "×", "✕", "✖", "╳", "✗"].contains(symbol) else { return nil }
            let frame = Rect(
                x: text.box.x * screen.width, y: text.box.y * screen.height,
                width: text.box.width * screen.width, height: text.box.height * screen.height
            )
            guard frame.width > 0, frame.height > 0,
                  frame.width <= screen.width * 0.16, frame.height <= screen.height * 0.09 else { return nil }
            let point = frame.centre
            let nearTop = point.y >= content.y - screen.height * 0.08 &&
                point.y <= content.y + content.height * 0.2
            let nearCorner = point.x <= content.x + content.width * 0.2 ||
                point.x >= content.maxX - content.width * 0.2
            let belowCentre = abs(point.x - content.centre.x) <= content.width * 0.2 &&
                point.y >= content.maxY - content.height * 0.1 &&
                point.y <= content.maxY + screen.height * 0.15
            guard (nearTop && nearCorner && point.x >= content.x - screen.width * 0.05 &&
                   point.x <= content.maxX + screen.width * 0.05) || belowCentre else { return nil }
            return frame
        }
        // Multiple plausible X marks need visual confirmation rather than a guessed target.
        guard matches.count == 1, let frame = matches.first else { return nil }
        return Element(type: "Button", label: "关闭弹窗", value: nil, identifier: nil,
                       frame: frame, depth: 0, fromPicture: true)
    }
}

extension Element {
    var isPopupClose: Bool {
        fromPicture && type == "Button" && label == "关闭弹窗"
    }
}

extension Computer {
    /// OCR references are coordinates, so recheck them before sending the touch.
    func popupCloseStillVisible(_ previous: Element, until: Double) async -> Bool {
        guard let screen = size, let app = lastForeground?.bundleID, until - now() > 1.8 else { return false }
        let timeout = max(0.3, min(config.readTimeout, until - now() - 1.5))
        let reading = await runner.read(timeout: timeout, format: config.treeFormat, callEnds: until)
        guard reading.foreground?.bundleID == app, let png = reading.png,
              let popup = PokiOverlay.detect(in: reading.elements, screen: screen) else { return false }
        let left = min(3.5, until - now() - 0.6)
        guard left >= 0.3 else { return false }
        let host = self.host
        guard let texts = (try? await withDeadline(left, "checking popup close", {
            await host.recognizeText(inPNG: png)
        })) ?? nil, let close = popup.closeControl(in: texts), !Task.isCancelled else { return false }
        return close.frame.contains(previous.frame.centre)
    }
}
