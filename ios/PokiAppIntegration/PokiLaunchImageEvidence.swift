import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// A launch image can precede an otherwise current accessibility tree.
enum PokiLaunchImageEvidence {
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
