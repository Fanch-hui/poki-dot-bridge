import XCTest
@testable import PokiCore
#if canImport(CoreGraphics) && canImport(ImageIO) && os(macOS)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class PokiDismissalEvidenceTests: XCTestCase {
    private let frame = [175.0, 715, 40, 40]

    private func screen(ring: Bool = true, cross: Bool = true, light: Bool = true) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 390, height: 844, bitsPerComponent: 8,
                                             bytesPerRow: 390, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(gray: light ? 0.4 : 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
        context.setFillColor(CGColor(gray: 0.94, alpha: 1))
        context.fill(CGRect(x: 17, y: 143, width: 356, height: 600))
        let x = 195.0, y = 844.0 - 735
        context.setStrokeColor(CGColor(gray: light ? 0.98 : 0.2, alpha: 1))
        context.setLineWidth(1.35)
        if ring { context.strokeEllipse(in: CGRect(x: x - 19, y: y - 19, width: 38, height: 38)) }
        if cross {
            context.move(to: CGPoint(x: x - 6, y: y - 6))
            context.addLine(to: CGPoint(x: x + 6, y: y + 6))
            context.move(to: CGPoint(x: x - 6, y: y + 6))
            context.addLine(to: CGPoint(x: x + 6, y: y - 6))
            context.strokePath()
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func install(_ wda: FakeWDA, picture: Data, blockingButton: Bool = false) {
        wda.tree([
            Node("Other", "关闭选规格", frame),
            Node("Other", "底部操作栏", [0, 710, 390, 76]),
        ] + (blockingButton ? [Node("Button", "确认支付", frame)] : []), app: "Shop")
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.base64EncodedString())]) }
    }

    private func reference(_ result: ToolResult) throws -> (line: String, ref: Int) {
        let entry = try XCTUnwrap(result.text.split(separator: "\n").first { $0.contains("Other \"关闭选规格\"") }, result.text)
        let ref = try XCTUnwrap(entry.split(separator: " ").first.flatMap { Int($0) }, result.text)
        return (String(entry), ref)
    }

    func testVisibleCircularCloseCanBeTappedDespiteTreeOrder() async throws {
        let wda = FakeWDA()
        install(wda, picture: try screen())
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let observed = try reference(await core.call("look", [:]))
        XCTAssertFalse(observed.line.contains("[covered]"), observed.line)
        let result = await core.call("do", ["actions": [["tap": .number(Double(observed.ref))]]])
        XCTAssertFalse(result.isError, result.text)
        let tap = try XCTUnwrap(wda.bodies("POST /wda/tap").first, result.text)
        XCTAssertEqual(tap["x"]?.double, 195)
        XCTAssertEqual(tap["y"]?.double, 735)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testCloseDisappearingFromCurrentPictureRemainsBlocked() async throws {
        let wda = FakeWDA()
        install(wda, picture: try screen(light: false))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let observed = try reference(await core.call("look", [:]))
        XCTAssertFalse(observed.line.contains("[covered]"), observed.line)
        install(wda, picture: try screen(cross: false))

        let result = await core.call("do", ["actions": [["tap": .number(Double(observed.ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testRealCompetingButtonStillBlocksCloseDespiteMatchingArtwork() async throws {
        let wda = FakeWDA()
        install(wda, picture: try screen(), blockingButton: true)
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
        let observed = try reference(await core.call("look", [:]))
        XCTAssertTrue(observed.line.contains("[covered]"), observed.line)

        let result = await core.call("do", ["actions": [["tap": .number(Double(observed.ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }
}
#endif
