@testable import PortlyApp
import PortlyCore
import XCTest

@MainActor
final class TemporaryProcessTests: XCTestCase {
    func testPortlyStatusDecodesOlderPayloadWithoutTemporaryServers() throws {
        let payload = Data(#"{"version":"0.1.10","apiPort":7737,"projects":[]}"#.utf8)

        let status = try PortlyAPI.decoder().decode(PortlyStatus.self, from: payload)

        XCTAssertTrue(status.temporaryServers.isEmpty)
    }

    func testManagedRuleUpgradeReplacesOldBlockAndPreservesSurroundings() {
        let old = """
        Before
        <!-- portly:managed-rule:start -->
        old rule
        <!-- portly:managed-rule:end -->
        After
        """

        let updated = AgentSetup.installManagedRule(in: old)

        XCTAssertTrue(updated.contains("Before"))
        XCTAssertTrue(updated.contains("After"))
        XCTAssertTrue(updated.contains("portly temp '<command>'"))
        XCTAssertTrue(updated.contains("portly wait \"$job_id\""))
        XCTAssertTrue(updated.contains("exits with code `124`"))
        XCTAssertFalse(updated.contains("old rule"))
        XCTAssertEqual(updated.components(separatedBy: "portly:managed-rule:start").count - 1, 1)
    }

    func testTemporaryTimeoutParsesFriendlyDurations() {
        XCTAssertEqual(TemporaryTimeout.parse("45"), 45)
        XCTAssertEqual(TemporaryTimeout.parse("30s"), 30)
        XCTAssertEqual(TemporaryTimeout.parse("1.5m"), 90)
        XCTAssertEqual(TemporaryTimeout.parse("2h"), 7_200)
        XCTAssertNil(TemporaryTimeout.parse("0"))
        XCTAssertNil(TemporaryTimeout.parse("forever"))
        XCTAssertNil(TemporaryTimeout.parse("8d"))
    }

    func testTemporaryJobMapsTerminalStateToShellExitCode() {
        let base = TemporaryJobStatus(
            id: "tmp_test",
            name: "build",
            command: "npm run build",
            directory: "/tmp",
            state: .succeeded,
            pid: nil,
            startedAt: Date(),
            finishedAt: Date(),
            timeoutSeconds: 60,
            deadline: Date(),
            exitCode: 0,
            error: nil
        )

        XCTAssertEqual(base.processExitCode, 0)
        var failed = base
        failed.state = .failed
        failed.exitCode = 7
        XCTAssertEqual(failed.processExitCode, 7)
        var timedOut = base
        timedOut.state = .timedOut
        timedOut.exitCode = nil
        XCTAssertEqual(timedOut.processExitCode, 124)
    }

    func testRawWaitStatusIsNormalizedBeforeExposingExitCode() {
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(0), 0)
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(7 << 8), 7)
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(15), 143)
        XCTAssertNil(ServerRuntime.normalizedProcessExitCode(nil))
    }
}
