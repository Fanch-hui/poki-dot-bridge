import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// A launch image can precede an otherwise current accessibility tree.
enum PokiLaunchImageEvidence {
    struct ChangedLabel {
        let before: String
        let after: String
        let beforeFrame: Rect
        let afterFrame: Rect
    }

    /// Find text that changed at the same screen position, such as a selected option summary.
    static func changedLabels(before: [Element], after: [Element], screen: ScreenSize) -> [ChangedLabel] {
        let viewport = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        func usable(_ element: Element) -> Bool {
            guard ["StaticText", "Button"].contains(element.type), !element.fromPicture,
                  normalized(element.text).count >= 6 else { return false }
            return !element.frame.isEmpty && element.frame.intersection(viewport).area >= element.frame.area * 0.9
        }
        func samePosition(_ first: Element, _ second: Element) -> Bool {
            first.type == second.type && first.frame.intersection(second.frame).area >= max(first.frame.area, second.frame.area) * 0.8
        }
        let previous = before.filter(usable)
        let current = after.filter(usable)
        return current.compactMap { element in
            guard current.filter({ samePosition($0, element) }).count == 1 else { return nil }
            let candidates = previous.filter { samePosition($0, element) }
            guard candidates.count == 1, let old = candidates.first else { return nil }
            let oldText = normalized(old.text), newText = normalized(element.text)
            guard oldText != newText else { return nil }
            return ChangedLabel(before: oldText, after: newText, beforeFrame: old.frame, afterFrame: element.frame)
        }
    }

    /// Both screenshots must show their own distinct version of the changed text in its frame.
    static func confirmsChangedLabel(_ labels: [ChangedLabel], before: [RecognizedText],
                                     after: [RecognizedText], screen: ScreenSize) -> Bool {
        labels.contains { label in
            witness(in: before, frame: label.beforeFrame, text: label.before, other: label.after, screen: screen) &&
                witness(in: after, frame: label.afterFrame, text: label.after, other: label.before, screen: screen)
        }
    }

    private static func witness(in texts: [RecognizedText], frame: Rect, text: String, other: String,
                                screen: ScreenSize) -> Bool {
        texts.contains { item in
            let value = normalized(item.text)
            guard value.count >= 6, text.contains(value), !other.contains(value) else { return false }
            let box = Rect(x: item.box.x * screen.width, y: item.box.y * screen.height,
                           width: item.box.width * screen.width, height: item.box.height * screen.height)
            return !box.isEmpty && frame.intersection(box).area >= box.area * 0.8
        }
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func hasMissingLabels(_ reading: Reading, screen: ScreenSize) -> Bool {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let png = reading.png, screen.width > 0, screen.height > 0 else { return false }
        let candidates = reading.elements.filter { element in
            guard ["StaticText", "Button"].contains(element.type), !element.fromPicture,
                  let label = element.label, (2...35).contains(label.count) else { return false }
            let frame = element.frame
            return frame.x >= 0 && frame.y >= screen.height * 0.07 &&
                frame.maxX <= screen.width && frame.maxY <= screen.height &&
                frame.width >= screen.width * 0.045 && frame.width <= screen.width * 0.76 &&
                frame.height >= screen.height * 0.013 && frame.height <= screen.height * 0.088
        }
        guard candidates.count >= 8,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }

        let width = 105, height = 228
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return false }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var checked = 0
        var missing = 0
        var sampledFrames: [Rect] = []
        for element in candidates {
            let frame = element.frame
            if sampledFrames.contains(where: {
                $0.intersection(frame).area >= min($0.area, frame.area) * 0.7
            }) { continue }
            let x0 = max(0, min(width, Int(frame.x * Double(width) / screen.width)))
            let y0 = max(0, min(height, Int(frame.y * Double(height) / screen.height)))
            let x1 = max(0, min(width, Int(frame.maxX * Double(width) / screen.width)))
            let y1 = max(0, min(height, Int(frame.maxY * Double(height) / screen.height)))
            guard x1 - x0 >= 3, y1 - y0 >= 3 else { continue }
            sampledFrames.append(frame)
            var samples: [UInt8] = []
            samples.reserveCapacity((x1 - x0) * (y1 - y0))
            for y in y0..<y1 {
                for x in x0..<x1 { samples.append(pixels[y * width + x]) }
            }
            samples.sort()
            checked += 1
            let low = samples[(samples.count - 1) / 100]
            let high = samples[(samples.count - 1) * 99 / 100]
            if Int(high) - Int(low) <= 8 { missing += 1 }
            if checked == 50 { break }
        }
        return missing >= 8 && missing * 5 >= checked * 2
        #else
        return false
        #endif
    }
}
