import AppKit
import Charts
import SwiftUI
@testable import PortlyApp
import XCTest

final class ResourceDashboardTests: XCTestCase {
    private let mib = UInt64(1_048_576)
    private let gib = UInt64(1_073_741_824)

    func testProjectChartScaleRendersRetainedHistoryForStoppedProject() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let history = [
            ProjectResourceHistoryPoint(
                timestamp: now,
                projectID: "active-project",
                projectName: "Shared name",
                colorHex: "#FF9F0A",
                footprintBytes: 1_073_741_824,
                residentBytes: 536_870_912
            ),
            ProjectResourceHistoryPoint(
                timestamp: now,
                projectID: "stopped-project",
                projectName: "Shared name",
                colorHex: "#0A84FF",
                footprintBytes: 536_870_912,
                residentBytes: 268_435_456
            ),
        ]
        let styles = DashboardProjectChartStyleScale.make(
            history: history,
            activeProjects: [
                (id: "active-project", name: "Shared name", colorHex: "#FF9F0A"),
            ]
        )

        XCTAssertEqual(Set(styles.map(\.id)), ["active-project", "stopped-project"])

        let host = NSHostingView(rootView: ProjectHistoryChartFixture(history: history, styles: styles))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        host.layoutSubtreeIfNeeded()
    }

    func testNextColorSkipsColorsAlreadyTaken() {
        let taken = Array(Supervisor.palette.prefix(3))

        XCTAssertEqual(Supervisor.nextColor(excluding: taken), Supervisor.palette[3])
        XCTAssertEqual(Supervisor.nextColor(excluding: []), Supervisor.palette[0])
        // Case differences in a hand-edited config must not read as a free color.
        XCTAssertEqual(
            Supervisor.nextColor(excluding: [Supervisor.palette[0].lowercased()]),
            Supervisor.palette[1]
        )
    }

    func testNextColorFallsBackToTheLeastUsedColorOnceEveryOneIsTaken() {
        let everything = Supervisor.palette + Supervisor.palette.dropLast()

        XCTAssertEqual(Supervisor.nextColor(excluding: everything), Supervisor.palette.last)
    }

    func testProjectChartScaleGivesColorTwinsDifferentDashPatterns() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let shared = "#64D2FF"
        let styles = DashboardProjectChartStyleScale.make(
            history: ["alpha", "beta"].map { id in
                ProjectResourceHistoryPoint(
                    timestamp: now,
                    projectID: id,
                    projectName: id,
                    colorHex: shared,
                    footprintBytes: gib,
                    residentBytes: gib / 2
                )
            },
            activeProjects: []
        )

        XCTAssertEqual(styles.map(\.colorHex), [shared, shared])
        XCTAssertNotEqual(styles[0].dash, styles[1].dash)
    }

    func testProjectChartScaleKeepsDashPatternWhenFootprintsChange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let projects = [
            (id: "codeline", name: "codeline-app", colorHex: "#0A84FF"),
            (id: "lumail", name: "lumail.io", colorHex: "#FF9F0A"),
        ]
        let dashes = { (footprint: UInt64) in
            DashboardProjectChartStyleScale.make(
                history: projects.map { project in
                    ProjectResourceHistoryPoint(
                        timestamp: now,
                        projectID: project.id,
                        projectName: project.name,
                        colorHex: project.colorHex,
                        footprintBytes: project.id == "lumail" ? footprint : self.gib,
                        residentBytes: self.gib / 2
                    )
                },
                activeProjects: projects
            )
            .reduce(into: [String: [CGFloat]]()) { $0[$1.id] = $1.dash }
        }

        XCTAssertEqual(dashes(gib / 4), dashes(12 * gib))
    }

    func testDiagnosticsFlagMachineAdjustedCriticalServerWithFrameworkAdvice() {
        let server = diagnosticServer(
            memoryBytes: 4 * gib,
            command: "node node_modules/next/dist/bin/next dev"
        )

        let diagnostics = MemoryDiagnosticsEngine.analyze(
            servers: [server],
            projectHistory: [],
            externalProcesses: [],
            physicalMemoryBytes: 16 * gib
        )

        XCTAssertEqual(diagnostics.first?.severity, .critical)
        XCTAssertEqual(diagnostics.first?.serverID, server.id)
        XCTAssertTrue(diagnostics.first?.fix.contains("Next.js") == true)
    }

    func testDiagnosticsDetectSustainedGrowthUsingWindowMedians() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let values = [300, 310, 320, 420, 560, 700, 820, 940, 1_080, 1_180, 1_260, 1_340]
        let history = values.enumerated().map { index, value in
            ProjectResourceHistoryPoint(
                timestamp: now.addingTimeInterval(Double(index * 5)),
                projectID: "project",
                projectName: "Growing app",
                colorHex: "#FF9F0A",
                footprintBytes: UInt64(value) * mib,
                residentBytes: UInt64(value) * mib / 2
            )
        }

        let diagnostics = MemoryDiagnosticsEngine.analyze(
            servers: [diagnosticServer(memoryBytes: 600 * mib, command: "node server.js")],
            projectHistory: history,
            externalProcesses: [],
            physicalMemoryBytes: 16 * gib
        )

        let growth = diagnostics.first { $0.id == "growth-project" }
        XCTAssertEqual(growth?.severity, .critical)
        XCTAssertTrue(growth?.summary.contains("one-off build spikes") == true)
    }

    func testDiagnosticsIgnoreOneOffBuildSpike() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let values = [300, 305, 310, 2_000, 315, 320, 325, 330, 335, 340, 345, 350]
        let history = values.enumerated().map { index, value in
            ProjectResourceHistoryPoint(
                timestamp: now.addingTimeInterval(Double(index * 5)),
                projectID: "project",
                projectName: "Build spike",
                colorHex: "#0A84FF",
                footprintBytes: UInt64(value) * mib,
                residentBytes: UInt64(value) * mib / 2
            )
        }

        let diagnostics = MemoryDiagnosticsEngine.analyze(
            servers: [diagnosticServer(memoryBytes: 350 * mib, command: "node server.js")],
            projectHistory: history,
            externalProcesses: [],
            physicalMemoryBytes: 16 * gib
        )

        XCTAssertFalse(diagnostics.contains { $0.id == "growth-project" })
        XCTAssertEqual(diagnostics.first?.severity, .healthy)
    }

    func testDiagnosticsNeverOffersManagedActionForExternalProcess() {
        let external = ExternalProcessSnapshot(
            pid: 44,
            parentPID: 1,
            command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            cpuPercent: 2,
            memoryBytes: 2 * gib,
            residentMemoryBytes: 1_500 * mib
        )

        let diagnostics = MemoryDiagnosticsEngine.analyze(
            servers: [],
            projectHistory: [],
            externalProcesses: [external],
            physicalMemoryBytes: 16 * gib
        )

        XCTAssertEqual(diagnostics.first?.id, "external-44")
        XCTAssertNil(diagnostics.first?.serverID)
        XCTAssertEqual(diagnostics.first?.processID, 44)
        XCTAssertTrue(diagnostics.first?.fix.contains("tabs") == true)
    }

    func testExternalAppDisplayNameHandlesSpaces() {
        let process = ExternalProcessSnapshot(
            pid: 44,
            parentPID: 1,
            command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=renderer",
            cpuPercent: 0,
            memoryBytes: gib,
            residentMemoryBytes: gib
        )

        XCTAssertEqual(process.displayName, "Google Chrome")
    }

    func testLiveSamplerReturnsBoundedSortedCurrentUserProcesses() {
        let sample = ProcessMetricsSampler.sample(
            rootProcessIDs: [],
            includeExternalDetails: false
        )

        XCTAssertTrue(sample.managedByRoot.isEmpty)
        XCTAssertLessThanOrEqual(sample.externalProcesses.count, 30)
        XCTAssertFalse(sample.externalProcesses.contains { $0.pid == getpid() })
        XCTAssertEqual(
            sample.externalProcesses.map(\.residentMemoryBytes),
            sample.externalProcesses.map(\.residentMemoryBytes).sorted(by: >)
        )
    }

    private func diagnosticServer(
        memoryBytes: UInt64,
        command: String
    ) -> MemoryServerDiagnosticSnapshot {
        let process = ManagedProcessSnapshot(
            pid: 100,
            parentPID: 99,
            command: command,
            cpuPercent: 5,
            memoryBytes: memoryBytes,
            residentMemoryBytes: memoryBytes / 2
        )
        return MemoryServerDiagnosticSnapshot(
            id: "server",
            projectID: "project",
            fullName: "Project / dev",
            metrics: ProcessMetrics(
                cpuPercent: 5,
                memoryBytes: memoryBytes,
                residentMemoryBytes: memoryBytes / 2,
                processCount: 1,
                processes: [process]
            )
        )
    }
}

private struct ProjectHistoryChartFixture: View {
    let history: [ProjectResourceHistoryPoint]
    let styles: [DashboardProjectChartStyle]

    var body: some View {
        Chart(history) { point in
            LineMark(
                x: .value("Time", point.timestamp),
                y: .value("Footprint", Double(point.footprintBytes)),
                series: .value("Project", point.projectID)
            )
            .foregroundStyle(by: .value("Project", point.projectID))
        }
        .chartForegroundStyleScale(
            domain: styles.map(\.id),
            range: styles.map { Color(hex: $0.colorHex) }
        )
        .frame(width: 800, height: 300)
    }
}
