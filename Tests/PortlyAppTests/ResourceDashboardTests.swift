import AppKit
import Charts
import SwiftUI
@testable import PortlyApp
import XCTest

final class ResourceDashboardTests: XCTestCase {
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
