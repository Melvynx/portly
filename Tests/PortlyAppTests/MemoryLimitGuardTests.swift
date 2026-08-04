@testable import PortlyApp
import PortlyCore
import XCTest

final class MemoryLimitGuardTests: XCTestCase {
    func testRequiresThreeConsecutiveSamplesBeforeRestart() {
        var guardrail = MemoryLimitGuard()
        let limit: UInt64 = 5 * 1_073_741_824

        XCTAssertFalse(guardrail.shouldRestart(
            projectID: "project", footprintBytes: limit + 1, limitBytes: limit,
            hasRunningServers: true
        ))
        XCTAssertFalse(guardrail.shouldRestart(
            projectID: "project", footprintBytes: limit + 1, limitBytes: limit,
            hasRunningServers: true
        ))
        XCTAssertTrue(guardrail.shouldRestart(
            projectID: "project", footprintBytes: limit + 1, limitBytes: limit,
            hasRunningServers: true
        ))
    }

    func testBelowLimitAndRestartResetConsecutiveSamples() {
        var guardrail = MemoryLimitGuard()
        let limit: UInt64 = 1_000

        XCTAssertFalse(sample(&guardrail, bytes: 1_001, limit: limit))
        XCTAssertFalse(sample(&guardrail, bytes: 999, limit: limit))
        XCTAssertFalse(sample(&guardrail, bytes: 1_001, limit: limit))
        XCTAssertFalse(sample(&guardrail, bytes: 1_001, limit: limit))
        XCTAssertTrue(sample(&guardrail, bytes: 1_001, limit: limit))

        XCTAssertFalse(sample(&guardrail, bytes: 2_000, limit: limit))
        XCTAssertFalse(sample(&guardrail, bytes: 2_000, limit: limit))
        XCTAssertTrue(sample(&guardrail, bytes: 2_000, limit: limit))
    }

    func testMemorySizeAndProjectPolicies() {
        XCTAssertEqual(MemorySize.parse("5GB"), 5 * 1_073_741_824)
        XCTAssertEqual(MemorySize.parse("5 Go"), 5 * 1_073_741_824)
        XCTAssertEqual(MemorySize.parse("512mb"), 512 * 1_048_576)
        XCTAssertNil(MemorySize.parse("64MB"))

        let global: UInt64 = 5 * 1_073_741_824
        var project = Project(name: "App", root: "/tmp")
        XCTAssertEqual(project.effectiveMemoryLimit(global: global), global)
        project.memoryLimitMode = .disabled
        XCTAssertNil(project.effectiveMemoryLimit(global: global))
        project.memoryLimitMode = .custom
        project.memoryLimitBytes = 2 * 1_073_741_824
        XCTAssertEqual(project.effectiveMemoryLimit(global: global), 2 * 1_073_741_824)
    }

    func testOlderConfigDefaultsMemoryGuardToOffAndProjectsToInherit() throws {
        let payload = Data(#"{"version":1,"projects":[{"name":"App","root":"/tmp"}]}"#.utf8)
        let config = try PortlyAPI.decoder().decode(PortlyConfig.self, from: payload)

        XCTAssertNil(config.globalMemoryLimitBytes)
        XCTAssertEqual(config.projects.first?.memoryLimitMode, .inherit)
        XCTAssertNil(config.projects.first?.memoryLimitBytes)
    }

    private func sample(
        _ guardrail: inout MemoryLimitGuard,
        bytes: UInt64,
        limit: UInt64
    ) -> Bool {
        guardrail.shouldRestart(
            projectID: "project",
            footprintBytes: bytes,
            limitBytes: limit,
            hasRunningServers: true
        )
    }
}
