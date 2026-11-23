import Foundation
import ObjectiveC.runtime
import XCTest
@testable import Poki

final class PokiLaunchProofTests: XCTestCase {
    func testLaunchReadinessUsesSystemProofAndFallsBack() async {
        let results = await Task.detached {
            let native = PKInProcess.shared()
            _ = native.close()
            let launch = Proof(native.prepareForAppLaunch())
            let cached = Proof(native.prepare())
            _ = native.close()
            let ordinary = Proof(native.prepare())
            _ = native.close()

            let selector = NSSelectorFromString("systemApplication")
            guard let ax = NSClassFromString("XCAXClient_iOS"),
                  let method = class_getInstanceMethod(ax, selector) else {
                return [launch, cached, ordinary]
            }
            // The first system lookup fails; subsequent foreground lookups use the real AX endpoint.
            typealias SystemApplication = @convention(c) (AnyObject, Selector) -> AnyObject?
            let previous = method_getImplementation(method)
            let getSystem = unsafeBitCast(previous, to: SystemApplication.self)
            var firstRequest = true
            let emptySystem: @convention(block) (AnyObject) -> AnyObject? = { object in
                if firstRequest {
                    firstRequest = false
                    return nil
                }
                return getSystem(object, selector)
            }
            let replacement = imp_implementationWithBlock(emptySystem)
            method_setImplementation(method, replacement)
            let fallback = Proof(native.prepareForAppLaunch())
            method_setImplementation(method, previous)
            imp_removeBlock(replacement)
            _ = native.close()

            native.failNextReadinessCheck = true
            let unreadable = Proof(native.prepareForAppLaunch())
            let afterFailure = Proof(native.prepareForAppLaunch())
            _ = native.close()
            return [launch, cached, ordinary, fallback, unreadable, afterFailure]
        }.value

        XCTAssertEqual(results.count, 6, "The simulator must expose the system AX endpoint.")
        guard results.count == 6 else { return }
        XCTAssertTrue(results[0].ok, results[0].detail)
        XCTAssertEqual(results[0].mode, "system")
        XCTAssertNotNil(results[0].sessionSeconds)
        XCTAssertNotNil(results[0].proofSeconds)
        XCTAssertEqual(results[1].mode, "cached")
        XCTAssertTrue(results[2].ok, results[2].detail)
        XCTAssertEqual(results[2].mode, "full")
        XCTAssertTrue(results[3].ok, results[3].detail)
        XCTAssertEqual(results[3].mode, "full")
        XCTAssertFalse(results[4].ok)
        XCTAssertEqual(results[4].code, "session_unreadable")
        XCTAssertTrue(results[5].ok, results[5].detail)
        XCTAssertNotEqual(results[4].generation, results[5].generation)
    }
}

private struct Proof: Sendable {
    let ok: Bool
    let mode: String?
    let code: String?
    let detail: String
    let generation: UInt64?
    let sessionSeconds: Double?
    let proofSeconds: Double?

    init(_ result: [String: Any]) {
        ok = result["ok"] as? Bool == true
        mode = result["readiness_check"] as? String
        code = result["code"] as? String
        detail = "\(result)"
        generation = (result["generation"] as? NSNumber)?.uint64Value
        sessionSeconds = result["seconds"] as? Double
        proofSeconds = result["warm_seconds"] as? Double
    }
}
