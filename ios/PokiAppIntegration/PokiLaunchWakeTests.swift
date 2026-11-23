import Foundation
import XCTest
@testable import PokiCore

final class PokiLaunchWakeTests: XCTestCase {
    private final class Host: CoreHost, Sendable {
        let state = LockedBox<RunnerState>(.running)
        let request = LockedBox<PokiLaunchWake?>(nil)
        let measurementsAvailable = LockedBox(true)
        var currentRunner: RunnerState { state.value }
        func runnerState() -> RunnerState {
            let wake = PokiLaunchWake.current
            request.value = wake
            if measurementsAvailable.value {
                wake?.record(sessionSeconds: 0.21, proofSeconds: 0.03, check: "system")
            }
            return state.value
        }
        func signingKey() throws -> RelayKey { FakeKey() }
        func accessHashes() -> [String] { [] }
        func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data { png }
        func restartRunner() {}
    }

    func testLaunchReportsOnlyItsOwnNativeMeasurements() async throws {
        var config = CoreConfig()
        config.standaloneObservations = true
        config.treeFormat = "json"
        let host = Host()
        let core = PokiCore(config: config, host: host, transport: FakeWDA())
        let launch: JSON = ["actions": [["launch": "com.apple.Preferences"]]]
        let first = await core.call("do", launch)
        XCTAssertFalse(first.isError, first.text)
        XCTAssertTrue(first.text.contains("launch_timing: session_open=210ms readability=30ms proof=system"), first.text)
        let wake = try XCTUnwrap(host.request.value)
        XCTAssertFalse(wake.isWaiting)

        host.measurementsAvailable.value = false
        let warm = await core.call("do", launch)
        XCTAssertFalse(warm.text.contains("session_open="), warm.text)
        let look = await core.call("look", [:])
        XCTAssertNil(host.request.value)
        XCTAssertFalse(look.text.contains("session_open="), look.text)
    }

    func testLaunchDeclinedBeforeReadinessCannotActivateTheApp() async throws {
        var config = CoreConfig()
        config.standaloneObservations = true
        let host = Host()
        host.state.value = .automationAuthorizationDeclined("declined", fix: "owner action required")
        let wda = FakeWDA()
        let core = PokiCore(config: config, host: host, transport: wda)
        let result = await core.call("do", ["actions": [["launch": "com.apple.Preferences"]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Nothing was sent"), result.text)
        XCTAssertFalse(try XCTUnwrap(host.request.value).isWaiting)
        XCTAssertTrue(wda.bodies("POST /wda/apps/activate").isEmpty)
    }

    func testCompoundAndUnresolvedActionsUseOrdinaryPreparation() {
        var config = CoreConfig()
        config.resolveApp = { $0 == "Shop" ? "com.example.shop" : nil }
        XCTAssertNil(PokiLaunchWake.forLaunch([["launch": "Unknown App"]], config: config))
        XCTAssertNil(PokiLaunchWake.forLaunch([["launch": "com.example.app"], ["tap": 1]], config: config))
        XCTAssertNil(PokiLaunchWake.forLaunch([["tap": 1, "launch": "com.example.app"]], config: config))
        XCTAssertNotNil(PokiLaunchWake.forLaunch([["launch": ["bundle": "com.example.app", "fresh": true]]], config: config))
        let path: JSON = ["path": ["steps": [["navigate": ["app": "Shop"]]]]]
        XCTAssertNotNil(PokiLaunchWake.forLaunch([path], config: config))
    }
}
