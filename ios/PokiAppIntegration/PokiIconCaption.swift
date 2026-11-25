import Foundation
#if canImport(Vision) && canImport(ImageIO)
import ImageIO
import Vision
#endif

enum PokiIconCaption {
    static func isTile(_ element: Element, frame: Rect, screen: ScreenSize) -> Bool {
        element.type == "Button" && frame.height >= 40 && frame.width <= screen.width / 3 &&
            frame.width >= frame.height * 0.7 && frame.width <= frame.height * 1.5
    }

    /// The full-page OCR can join a row of small captions. Read just the bottom of the named tile.
    static func recognize(in png: Data, frame: Rect, screen: ScreenSize, label: String) -> RecognizedText? {
        #if canImport(Vision) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let sx = Double(image.width) / screen.width, sy = Double(image.height) / screen.height
        let band = CGRect(x: frame.x * sx, y: (frame.maxY - frame.height / 3) * sy,
                          width: frame.width * sx, height: frame.height * sy / 3).integral
        guard let crop = image.cropping(to: band) else { return nil }
        let width = min(512, crop.width * 4), height = max(1, crop.height * width / crop.width)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if label.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        } else if #available(iOS 16, macOS 13, *) {
            request.automaticallyDetectsLanguage = true
        }
        do { try VNImageRequestHandler(cgImage: scaled).perform([request]) } catch { return nil }
        let matches = request.results?.filter {
            $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(label) == .orderedSame
        } ?? []
        guard matches.count == 1, let box = matches.first?.boundingBox else { return nil }
        return RecognizedText(text: label, box: Rect(
            x: (band.minX + box.minX * band.width) / Double(image.width),
            y: (band.minY + (1 - box.maxY) * band.height) / Double(image.height),
            width: box.width * band.width / Double(image.width),
            height: box.height * band.height / Double(image.height)))
        #else
        return nil
        #endif
    }
}
