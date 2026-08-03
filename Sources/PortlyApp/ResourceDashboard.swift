import Charts
import PortlyCore
import SwiftUI

struct ResourceDashboard: View {
    @EnvironmentObject private var supervisor: Supervisor

    private var serverRows: [DashboardServerRow] {
        supervisor.runtimes.values.compactMap { runtime in
            guard let metrics = runtime.processMetrics else { return nil }
            return DashboardServerRow(
                id: runtime.id,
                projectID: runtime.projectID,
                projectName: runtime.projectName,
                projectColorHex: supervisor.projects.first(where: { $0.id == runtime.projectID })?.color ?? "#FF9F0A",
                name: runtime.config.name,
                state: runtime.state,
                metrics: metrics
            )
        }
        .sorted { lhs, rhs in
            if lhs.metrics.memoryBytes != rhs.metrics.memoryBytes {
                return lhs.metrics.memoryBytes > rhs.metrics.memoryBytes
            }
            return lhs.fullName.localizedStandardCompare(rhs.fullName) == .orderedAscending
        }
    }

    private var projectRows: [DashboardProjectRow] {
        let groups = Dictionary(grouping: serverRows) { $0.projectID }
        var rows: [DashboardProjectRow] = []
        for (projectID, servers) in groups {
            guard let first = servers.first else { continue }
            let footprint = servers.reduce(UInt64(0)) { $0 + $1.metrics.memoryBytes }
            let resident = servers.reduce(UInt64(0)) { $0 + $1.metrics.residentMemoryBytes }
            let cpu = servers.reduce(0.0) { $0 + $1.metrics.cpuPercent }
            let processCount = servers.reduce(0) { $0 + $1.metrics.processCount }
            rows.append(
                DashboardProjectRow(
                    id: projectID,
                    name: first.projectName,
                    colorHex: first.projectColorHex,
                    footprintBytes: footprint,
                    residentBytes: resident,
                    cpuPercent: cpu,
                    processCount: processCount,
                    serverCount: servers.count
                )
            )
        }
        return rows.sorted { lhs, rhs in
            if lhs.footprintBytes != rhs.footprintBytes {
                return lhs.footprintBytes > rhs.footprintBytes
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var processRows: [DashboardProcessRow] {
        serverRows.flatMap { server in
            server.metrics.processes.map { process in
                DashboardProcessRow(
                    id: "\(server.id)-\(process.pid)",
                    serverName: server.fullName,
                    serverState: server.state,
                    process: process
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.process.memoryBytes != rhs.process.memoryBytes {
                return lhs.process.memoryBytes > rhs.process.memoryBytes
            }
            return lhs.process.pid < rhs.process.pid
        }
    }

    private var totalFootprint: UInt64 {
        serverRows.reduce(0) { $0 + $1.metrics.memoryBytes }
    }

    private var totalResident: UInt64 {
        serverRows.reduce(0) { $0 + $1.metrics.residentMemoryBytes }
    }

    private var totalCPU: Double {
        serverRows.reduce(0) { $0 + $1.metrics.cpuPercent }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if serverRows.isEmpty {
                    emptyState
                } else {
                    overview
                    historyGrid
                    projectImpact
                    processes
                }
            }
            .padding(24)
            .frame(maxWidth: 1_440, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Resources")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Resource dashboard")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .textSelection(.enabled)
                Text("Live memory and CPU across every process Portly manages.")
                    .font(PortlyTypography.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label {
                Text("Live · 2 s")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            }
                .font(PortlyTypography.bodyMedium)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.green.opacity(0.1), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.green.opacity(0.2), lineWidth: 0.75)
                }
                .accessibilityLabel("Live data, updated every 2 seconds")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No active processes",
            systemImage: "chart.xyaxis.line",
            description: Text("Start a server to collect live resource data.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var overview: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
            spacing: 12
        ) {
            overviewCard(
                title: "Footprint",
                value: bytes(totalFootprint),
                detail: "Total owned memory",
                systemImage: "memorychip",
                color: .orange
            )
            overviewCard(
                title: "Resident",
                value: bytes(totalResident),
                detail: "Currently in RAM",
                systemImage: "memorychip.fill",
                color: .blue
            )
            overviewCard(
                title: "CPU",
                value: totalCPU.formatted(.number.precision(.fractionLength(1))) + "%",
                detail: "Across all cores",
                systemImage: "cpu",
                color: .purple
            )
            overviewCard(
                title: "Processes",
                value: String(processRows.count),
                detail: "Across \(serverRows.count) active servers",
                systemImage: "square.stack.3d.up",
                color: .cyan
            )
        }
    }

    private func overviewCard(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(PortlyTypography.bodyMedium)
                Spacer()
            }

            Text(value)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(detail)
                .font(PortlyTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }

    private var historyGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 480), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            memoryHistory
            projectHistory
        }
    }

    private var memoryHistory: some View {
        dashboardSection(
            title: "System pressure",
            subtitle: "All managed projects · five-minute window"
        ) {
            if supervisor.resourceHistory.count < 2 {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Collecting history…")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 18) {
                        legend("Footprint", color: .orange)
                        legend("Resident", color: .blue)
                    }

                    Chart(supervisor.resourceHistory) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Footprint", gibibytes(point.footprintBytes))
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange.opacity(0.24), .orange.opacity(0.015)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Footprint", gibibytes(point.footprintBytes)),
                            series: .value("Series", "Footprint")
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Resident", gibibytes(point.residentBytes)),
                            series: .value("Series", "Resident")
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    .chartLegend(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                            AxisValueLabel {
                                if let amount = value.as(Double.self) {
                                    Text(amount.formatted(.number.precision(.fractionLength(0...1))) + " GB")
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) {
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                            AxisValueLabel(format: .dateTime.minute().second())
                        }
                    }
                    .frame(minHeight: 220)
                    .accessibilityLabel("Memory history")
                    .accessibilityValue(
                        "Current footprint \(bytes(totalFootprint)); resident \(bytes(totalResident))"
                    )
                }
            }
        }
    }

    private var projectHistory: some View {
        let history = supervisor.projectResourceHistory
        let activeProjects = projectRows
        let styles = DashboardProjectChartStyleScale.make(
            history: history,
            activeProjects: activeProjects.map { project in
                (id: project.id, name: project.name, colorHex: project.colorHex)
            }
        )

        return dashboardSection(
            title: "Project history",
            subtitle: "Spot the project whose footprint keeps climbing"
        ) {
            if history.count < max(2, activeProjects.count * 2) {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Collecting project history…")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(styles) { style in
                            legend(style.name, color: Color(hex: style.colorHex))
                        }
                    }

                    Chart(history) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Footprint", gibibytes(point.footprintBytes)),
                            series: .value("Project", point.projectID)
                        )
                        .foregroundStyle(by: .value("Project", point.projectID))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    .chartForegroundStyleScale(
                        domain: styles.map(\.id),
                        range: styles.map { Color(hex: $0.colorHex) }
                    )
                    .chartLegend(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                            AxisValueLabel {
                                if let amount = value.as(Double.self) {
                                    Text(amount.formatted(.number.precision(.fractionLength(0...1))) + " GB")
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) {
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                            AxisValueLabel(format: .dateTime.minute().second())
                        }
                    }
                    .frame(minHeight: 220)
                    .accessibilityLabel("Memory footprint history by project")
                    .accessibilityValue("\(styles.count) projects in recent history")
                }
            }
        }
    }

    private var projectImpact: some View {
        dashboardSection(
            title: "Project impact",
            subtitle: "Every server aggregated by project · highest footprint first"
        ) {
            Chart(projectRows) { project in
                BarMark(
                    x: .value("Footprint", gibibytes(project.footprintBytes)),
                    y: .value("Project", project.name)
                )
                .foregroundStyle(Color(hex: project.colorHex).gradient)
                .cornerRadius(5)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(bytes(project.footprintBytes))
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(position: .bottom) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.precision(.fractionLength(0...1))) + " GB")
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisValueLabel()
                        .font(PortlyTypography.metadata)
                }
            }
            .frame(minHeight: max(190, CGFloat(projectRows.count) * 42))
            .accessibilityLabel("Memory footprint by project")
        }
    }

    private var processes: some View {
        dashboardSection(
            title: "Processes",
            subtitle: "Every managed descendant · sorted by footprint"
        ) {
            Table(processRows) {
                TableColumn("Process") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.process.displayName)
                            .font(PortlyTypography.bodyMedium)
                            .lineLimit(1)
                        Text(row.process.command)
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(row.process.command)
                    }
                    .accessibilityElement(children: .combine)
                }
                .width(min: 190, ideal: 300)

                TableColumn("Server") { row in
                    HStack(spacing: 7) {
                        StatusDot(state: row.serverState, size: 7)
                        Text(row.serverName)
                            .lineLimit(1)
                            .help(row.serverName)
                    }
                    .font(PortlyTypography.body)
                }
                .width(min: 150, ideal: 220)

                TableColumn("PID") { row in
                    Text(String(row.process.pid))
                        .monospacedDigit()
                }
                .width(min: 54, ideal: 64)

                TableColumn("CPU") { row in
                    Text(row.process.cpuPercent.formatted(.number.precision(.fractionLength(1))) + "%")
                        .monospacedDigit()
                }
                .width(min: 64, ideal: 76)

                TableColumn("Footprint") { row in
                    Text(bytes(row.process.memoryBytes))
                        .monospacedDigit()
                }
                .width(min: 86, ideal: 100)

                TableColumn("Resident") { row in
                    Text(bytes(row.process.residentMemoryBytes))
                        .monospacedDigit()
                }
                .width(min: 86, ideal: 100)
            }
            .font(PortlyTypography.body)
            .frame(minHeight: 360, idealHeight: 440, maxHeight: 520)
            .accessibilityLabel("Managed processes")
        }
    }

    private func dashboardSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PortlyTypography.title)
                Text(subtitle)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title)
                .font(PortlyTypography.bodyMedium)
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    private func gibibytes(_ value: UInt64) -> Double {
        Double(value) / 1_073_741_824
    }
}

private struct DashboardServerRow: Identifiable {
    let id: String
    let projectID: String
    let projectName: String
    let projectColorHex: String
    let name: String
    let state: ServerState
    let metrics: ProcessMetrics

    var fullName: String { "\(projectName) / \(name)" }
}

private struct DashboardProjectRow: Identifiable {
    let id: String
    let name: String
    let colorHex: String
    let footprintBytes: UInt64
    let residentBytes: UInt64
    let cpuPercent: Double
    let processCount: Int
    let serverCount: Int
}

private struct DashboardProcessRow: Identifiable {
    let id: String
    let serverName: String
    let serverState: ServerState
    let process: ManagedProcessSnapshot
}

struct DashboardProjectChartStyle: Identifiable, Equatable {
    let id: String
    let name: String
    let colorHex: String
}

enum DashboardProjectChartStyleScale {
    static func make(
        history: [ProjectResourceHistoryPoint],
        activeProjects: [(id: String, name: String, colorHex: String)]
    ) -> [DashboardProjectChartStyle] {
        var stylesByID: [String: DashboardProjectChartStyle] = [:]

        for point in history {
            stylesByID[point.projectID] = DashboardProjectChartStyle(
                id: point.projectID,
                name: point.projectName,
                colorHex: point.colorHex
            )
        }

        // Current configuration wins when a project was renamed or recolored,
        // while stopped projects remain in the domain until their history ages out.
        for project in activeProjects {
            stylesByID[project.id] = DashboardProjectChartStyle(
                id: project.id,
                name: project.name,
                colorHex: project.colorHex
            )
        }

        return stylesByID.values.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
