@testable import PortlyApp
import XCTest

final class ProcessControlTests: XCTestCase {
    func testStopTargetsRecommendedDevParentAndItsDescendants() throws {
        let snapshot = ExternalProcessSnapshot(
            pid: 30,
            parentPID: 20,
            command: "next-server (v16)",
            cpuPercent: 0,
            memoryBytes: 2_000,
            residentMemoryBytes: 1_000,
            parentCommand: "node next dev",
            workingDirectory: "/tmp/app",
            listeningPorts: [3000],
            terminationPID: 10,
            terminationCommand: "pnpm dev"
        )
        let processes = [
            ExternalProcessController.ProcessRecord(pid: 10, parentPID: 1, command: "pnpm dev"),
            ExternalProcessController.ProcessRecord(pid: 20, parentPID: 10, command: "node next dev"),
            ExternalProcessController.ProcessRecord(pid: 30, parentPID: 20, command: "next-server (v16)"),
            ExternalProcessController.ProcessRecord(pid: 40, parentPID: 30, command: "node worker.js"),
            ExternalProcessController.ProcessRecord(pid: 50, parentPID: 1, command: "unrelated"),
        ]
        var signaled: [Int32] = []

        let result = try ExternalProcessController.stop(
            snapshot,
            currentProcesses: processes,
            sendTerm: { pid in
                signaled.append(pid)
                return true
            }
        ).get()

        XCTAssertEqual(result.targetPID, 10)
        XCTAssertEqual(signaled.first, 10)
        XCTAssertEqual(Set(signaled), [10, 20, 30, 40])
        XCTAssertFalse(signaled.contains(50))
    }

    func testStopRefusesPIDReusedByAnotherCommand() {
        let snapshot = ExternalProcessSnapshot(
            pid: 30,
            parentPID: 1,
            command: "tsserver",
            cpuPercent: 0,
            memoryBytes: 2_000,
            residentMemoryBytes: 1_000,
            parentCommand: nil,
            workingDirectory: nil,
            listeningPorts: [],
            terminationPID: 30,
            terminationCommand: "tsserver"
        )
        var signaled: [Int32] = []

        let result = ExternalProcessController.stop(
            snapshot,
            currentProcesses: [
                ExternalProcessController.ProcessRecord(pid: 30, parentPID: 1, command: "different process"),
            ],
            sendTerm: { pid in
                signaled.append(pid)
                return true
            }
        )

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(signaled.isEmpty)
    }

    func testDockerInspectFindsContainerPublishingExactHostPort() throws {
        let data = Data(
            """
            [{
              "Id": "abc123",
              "Name": "/lumail-dev-serverless-redis-http-1",
              "Config": {"Labels": {
                "com.docker.compose.project": "lumail-dev",
                "com.docker.compose.service": "serverless-redis-http"
              }},
              "NetworkSettings": {"Ports": {
                "80/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8079"}]
              }}
            }]
            """.utf8
        )

        let container = try DockerPortInspector.parseInspectResponse(data, publishing: 8079)

        XCTAssertEqual(container?.id, "abc123")
        XCTAssertEqual(container?.name, "lumail-dev-serverless-redis-http-1")
        XCTAssertEqual(container?.composeProject, "lumail-dev")
        XCTAssertEqual(container?.composeService, "serverless-redis-http")
        XCTAssertNil(try DockerPortInspector.parseInspectResponse(data, publishing: 8080))
    }
}
