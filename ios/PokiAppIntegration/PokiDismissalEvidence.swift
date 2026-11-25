import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// An accessibility layer can put the dimmed page above a floating close button.
/// A visible circle and cross corroborate the native target at its actual touch point.
enum PokiDismissalEvidence {
    private static let labels: Set<String> = [
        "关闭", "關閉", "关闭弹窗", "關閉彈窗", "关闭选规格", "關閉選規格", "关闭规格", "關閉規格",
        "close", "dismiss", "close dialog", "close modal", "close sheet", "close options",
    ]

    static func matches(_ target: Element) -> Bool {
        let frame = target.frame
        return !target.fromPicture && ["Button", "Image", "Other"].contains(target.type) &&
            labels.contains(target.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) &&
            (24...64).contains(frame.width) && (24...64).contains(frame.height) &&
            abs(frame.width - frame.height) <= 0.2 * max(frame.width, frame.height)
    }

    static func corroborates(_ target: Element, in elements: [Element], screen: ScreenSize, png: Data) -> Bool {
        guard matches(target), !elements.contains(where: \.isSecure) else { return false }
        let point = target.frame.centre
        guard elements.filter({ matches($0) && $0.frame.contains(point) }).count == 1 else { return false }
        let viewport = PokiControlTargets(elements, screen: screen).visibleFrame(target)
        guard viewport == target.frame else { return false }
        let layout = Layout(all: elements, screen: screen)
        let modalTypes = ["Alert", "Sheet", "Dialog", "Popover"]
        let competingTypes = ["Button", "Link", "Switch", "TextField", "SearchField", "Slider", "Stepper", "Tab"]
        let contact = Rect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        let competingLayer = elements.contains { layer in
            !layer.contains(target) && (modalTypes.contains(layer.type) ||
                (layer.type == "Keyboard" && layer.frame.intersects(contact)))
        }
        let competingControls = layout.covers(target) + elements.filter(target.contains)
        guard !competingLayer, !competingControls.contains(where: {
            let frame = $0.frame
            let compactHit = ["Image", "Other"].contains($0.type) && !$0.text.isEmpty &&
                frame.width >= target.frame.width / 2 && frame.width <= target.frame.width * 1.5 &&
                frame.height >= target.frame.height / 2 && frame.height <= target.frame.height * 1.5
            return (competingTypes.contains($0.type) || compactHit) && frame.intersects(contact)
        }) else { return false }
        return hasCircleAndCross(png, frame: target.frame, screen: screen)
    }

    private static func hasCircleAndCross(_ png: Data, frame: Rect, screen: ScreenSize) -> Bool {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        let side = 64
        let searchWidth = frame.width * 1.2, searchHeight = frame.height * 1.2
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let sx = Double(image.width) / screen.width, sy = Double(image.height) / screen.height
        let area = CGRect(x: (frame.centre.x - searchWidth / 2) * sx, y: (frame.centre.y - searchHeight / 2) * sy,
                          width: searchWidth * sx, height: searchHeight * sy).integral
        guard area.minX >= 0, area.minY >= 0, area.maxX <= CGFloat(image.width), area.maxY <= CGFloat(image.height),
              let crop = image.cropping(to: area),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }

        func shade(_ x: Double, _ y: Double) -> Int {
            let col = Int((x / 1.2 + 0.5) * Double(side)), row = Int((y / 1.2 + 0.5) * Double(side))
            return Int(data[row * side + col])
        }
        return [1, -1].contains { polarity in
            let ring = (0..<8).filter { direction in
                let angle = Double(direction) * .pi / 4
                let x = cos(angle), y = sin(angle)
                let base = max(polarity * shade(0.34 * x, 0.34 * y), polarity * shade(0.55 * x, 0.55 * y))
                return [0.42, 0.44, 0.46, 0.48, 0.50].contains { r in polarity * shade(r * x, r * y) - base >= 22 }
            }
            guard ring.count >= 6 else { return false }
            return [(1.0, 1.0), (-1, 1), (-1, -1), (1, -1)].allSatisfy { x, y in
                let base = max(polarity * shade(0.18 * x, 0.09 * y), polarity * shade(0.09 * x, 0.18 * y))
                return [0.08, 0.10, 0.12].contains { d in polarity * shade(d * x, d * y) - base >= 25 }
            }
        }
        #else
        return false
        #endif
    }
}

extension Computer {
    func recheckCircularDismissal(_ targets: [(ref: Int, element: Element)], kind: ActionKind,
                                 screen: ScreenSize, until: Double) async -> (all: [Element], foreground: Foreground)? {
        guard kind == .tap, targets.count == 1, let target = targets.first,
              PokiDismissalEvidence.matches(target.element), let app = lastForeground?.bundleID,
              let observed = lastCircularDismissals, observed.readAt == lastTreeAt,
              observed.nodes.contains(target.element.node),
              until - now() >= 0.9 else { return nil }
        let deadline = min(until - 0.2, now() + 1.6)
        let live = await runner.read(timeout: deadline - now(), format: config.treeFormat, callEnds: deadline,
                                     allowHostPicture: false, workspace: false)
        guard !Task.isCancelled, now() < until, !live.invalidatesReferences,
              let foreground = live.foreground, foreground.bundleID == app, let png = live.png else { return nil }
        let matches = live.elements.filter {
            $0.type == target.element.type && $0.label == target.element.label &&
                $0.identifier == target.element.identifier && $0.frame == target.element.frame
        }
        guard matches.count == 1, let close = matches.first,
              PokiDismissalEvidence.corroborates(close, in: live.elements, screen: screen, png: png) else { return nil }
        verifiedTargets[target.ref] = (close, close.frame.centre)
        return (live.elements, foreground)
    }
}
