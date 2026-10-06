@testable import PortlyApp
import PortlyCore
import XCTest

final class IdleTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testIdleOnlyAfterTimeoutWithoutActivity() {
        var tracker = IdleTracker()
        XCTAssertFalse(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(3_600)))

        tracker.reset(at: start)
        XCTAssertFalse(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(59)))
        XCTAssertTrue(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(60)))
    }

    func testOutputInputAndBusyCPUExtendTheDeadline() {
        var tracker = IdleTracker()
        tracker.reset(at: start)

        tracker.recordOutput(at: start.addingTimeInterval(50))
        XCTAssertFalse(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(100)))

        tracker.recordInput(at: start.addingTimeInterval(100))
        XCTAssertFalse(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(150)))

        tracker.recordCPU(IdleTracker.busyCPUPercent, at: start.addingTimeInterval(150))
        XCTAssertFalse(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(200)))
        XCTAssertTrue(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(210)))
    }

    func testBackgroundCPUDoesNotCountAsActivity() {
        var tracker = IdleTracker()
        tracker.reset(at: start)
        tracker.recordCPU(IdleTracker.busyCPUPercent - 0.1, at: start.addingTimeInterval(30))
        XCTAssertTrue(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(60)))
    }

    func testOutputAnsweringAHealthProbeIsIgnored() {
        var tracker = IdleTracker()
        tracker.reset(at: start)

        // "GET /health 200" printed right after Portly's probe.
        tracker.recordProbe(at: start.addingTimeInterval(30), interval: 10)
        tracker.recordOutput(at: start.addingTimeInterval(30.2))
        XCTAssertTrue(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(60)))

        // Real output between probes still counts.
        tracker.recordOutput(at: start.addingTimeInterval(35))
        XCTAssertFalse(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(60)))
    }

    func testFastStartupProbesKeepTheEchoWindowShort() {
        var tracker = IdleTracker()
        tracker.reset(at: start)
        tracker.recordProbe(at: start.addingTimeInterval(10), interval: 1)
        tracker.recordOutput(at: start.addingTimeInterval(10.5))
        XCTAssertFalse(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(60)))
    }

    func testClearStopsTrackingUntilTheNextLaunch() {
        var tracker = IdleTracker()
        tracker.reset(at: start)
        tracker.clear()
        XCTAssertNil(tracker.lastActivityAt)
        XCTAssertFalse(tracker.isIdle(timeoutSeconds: 60, now: start.addingTimeInterval(3_600)))
    }

    func testServerPolicyInheritsDisablesOrOverridesTheGlobalDefault() {
        var server = ServerConfig(name: "web", command: "pnpm dev")
        XCTAssertNil(server.effectiveIdleTimeout(global: nil))
        XCTAssertEqual(server.effectiveIdleTimeout(global: 1_800), 1_800)

        server.idleTimeoutSeconds = 0
        XCTAssertNil(server.effectiveIdleTimeout(global: 1_800))

        server.idleTimeoutSeconds = 600
        XCTAssertEqual(server.effectiveIdleTimeout(global: 1_800), 600)
        XCTAssertEqual(server.effectiveIdleTimeout(global: nil), 600)
    }

    func testIdleTimeoutParsingAndConfigRoundTrip() throws {
        XCTAssertEqual(IdleTimeout.parse("30m"), 1_800)
        XCTAssertEqual(IdleTimeout.parse("2h"), 7_200)
        XCTAssertNil(IdleTimeout.parse("30s"))
        XCTAssertNil(IdleTimeout.parse("8d"))
        XCTAssertEqual(IdleTimeout.describe(1_800), "30 minutes")
        XCTAssertEqual(IdleTimeout.describe(3_600), "1 hour")

        let legacy = Data(#"{"version":1,"projects":[{"name":"App","root":"/tmp","servers":[{"name":"web","command":"x"}]}]}"#.utf8)
        let decoded = try PortlyAPI.decoder().decode(PortlyConfig.self, from: legacy)
        XCTAssertNil(decoded.idleTimeoutSeconds)
        XCTAssertNil(decoded.projects.first?.servers.first?.idleTimeoutSeconds)

        var config = decoded
        config.idleTimeoutSeconds = 1_800
        config.projects[0].servers[0].idleTimeoutSeconds = 0
        let roundTrip = try PortlyAPI.decoder().decode(
            PortlyConfig.self,
            from: PortlyAPI.encoder().encode(config)
        )
        XCTAssertEqual(roundTrip.idleTimeoutSeconds, 1_800)
        XCTAssertEqual(roundTrip.projects.first?.servers.first?.idleTimeoutSeconds, 0)
    }
}
