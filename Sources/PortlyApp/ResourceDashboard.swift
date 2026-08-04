import AppKit
import Charts
import PortlyCore
import SwiftUI

struct ResourceDashboard: View {
    @EnvironmentObject private var supervisor: Supervisor
    @State private var pendingExternalStop: ExternalProcessSnapshot?
    @State private var processActionError: String?
    @State private var stoppingProcessIDs = Set<Int32>()

    private var serverRows: [DashboardServerRow] {
        supervisor.runtimes.values.compactMap { runtime in
            guard let metrics = runtime.processMetrics else { return nil }
            return DashboardServerRow(
                id: runtime.id,
                projectID: runtime.projectID,
                projectName: runtime.projectName,
                projectColorHex: supervisor.projects.first(where: { $0.id == runtime.projectID })?.color
                    ?? runtime.projectColorHex,
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

    private var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    private var externalProcesses: [ExternalProcessSnapshot] {
        Array(supervisor.externalProcesses.prefix(20))
    }

    private var diagnostics: [MemoryDiagnostic] {
        MemoryDiagnosticsEngine.analyze(
            servers: serverRows.map {
                MemoryServerDiagnosticSnapshot(
                    id: $0.id,
                    projectID: $0.projectID,
                    fullName: $0.fullName,
                    metrics: $0.metrics
                )
            },
            projectHistory: supervisor.projectResourceHistory,
            externalProcesses: externalProcesses,
            physicalMemoryBytes: physicalMemoryBytes
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if serverRows.isEmpty, externalProcesses.isEmpty {
                    emptyState
                } else {
                    overview
                    smartRecommendations
                    if !serverRows.isEmpty {
                        historyGrid
                        projectImpact
                        processes
                    }
                    if !externalProcesses.isEmpty {
                        outsidePortlyProcesses
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1_440, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Resources")
        .confirmationDialog(
            externalStopTitle,
            isPresented: Binding(
                get: { pendingExternalStop != nil },
                set: { if !$0 { pendingExternalStop = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingExternalStop
        ) { process in
            Button("Send SIGTERM", role: .destructive) {
                stopExternalProcess(process)
            }
            Button("Cancel", role: .cancel) {}
        } message: { process in
            Text(externalStopMessage(process))
        }
        .alert("Unable to stop process", isPresented: Binding(
            get: { processActionError != nil },
            set: { if !$0 { processActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(processActionError ?? "The process could not be stopped.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Resource dashboard")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .textSelection(.enabled)
                Text("Live process monitoring with machine-aware memory diagnostics and safe fixes.")
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
                title: "Managed footprint",
                value: bytes(totalFootprint),
                detail: "Owned, compressed, or swapped",
                systemImage: "memorychip",
                color: .orange
            )
            overviewCard(
                title: "Managed resident",
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
                detail: "Managed across \(serverRows.count) active servers",
                systemImage: "square.stack.3d.up",
                color: .cyan
            )
            overviewCard(
                title: "Machine memory",
                value: bytes(physicalMemoryBytes),
                detail: "Managed services currently resident: \(managedResidentPercent)",
                systemImage: "desktopcomputer",
                color: .green
            )
        }
    }

    private var managedResidentPercent: String {
        guard physicalMemoryBytes > 0 else { return "—" }
        return (Double(totalResident) / Double(physicalMemoryBytes))
            .formatted(.percent.precision(.fractionLength(1)))
    }

    private var smartRecommendations: some View {
        let highestSeverity = diagnostics.map(\.severity).max() ?? .healthy
        return dashboardSection(
            title: "Smart recommendations",
            subtitle: "\(highestSeverity.label) · thresholds adapt to this Mac and trends ignore one-off build spikes"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(diagnostics) { diagnostic in
                    diagnosticCard(diagnostic)
                }
            }
        }
    }

    private func diagnosticCard(_ diagnostic: MemoryDiagnostic) -> some View {
        let color = diagnostic.severity.color
        let externalProcess = externalProcess(for: diagnostic)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: diagnostic.severity.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(diagnostic.title)
                        .font(PortlyTypography.bodyMedium)
                        .textSelection(.enabled)
                    Text(diagnostic.summary)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                Text(diagnostic.severity.label.uppercased())
                    .font(PortlyTypography.label)
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background(color.opacity(0.1), in: Capsule())
            }

            Label(diagnostic.fix, systemImage: "wrench.and.screwdriver")
                .font(PortlyTypography.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let externalProcess {
                externalProcessDetails(externalProcess)
            }

            if diagnostic.serverID != nil || diagnostic.processID != nil {
                Divider()
                HStack(spacing: 8) {
                    if let serverID = diagnostic.serverID,
                       let runtime = supervisor.runtime(for: serverID) {
                        Button("Restart server") { runtime.restart() }
                            .buttonStyle(.borderedProminent)
                        Button("Stop server") { runtime.stop() }
                            .buttonStyle(.bordered)
                    } else if let externalProcess {
                        Button {
                            pendingExternalStop = externalProcess
                        } label: {
                            if stoppingProcessIDs.contains(externalProcess.terminationPID) {
                                Label("Stopping…", systemImage: "hourglass")
                            } else {
                                Label(
                                    externalProcess.terminationPID == externalProcess.pid
                                        ? "Stop process" : "Stop dev session",
                                    systemImage: "stop.fill"
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(stoppingProcessIDs.contains(externalProcess.terminationPID))

                        if let runtime = migrationRuntime(for: externalProcess) {
                            Button("Move to Portly") {
                                _ = runtime.takeOverPort()
                            }
                            .buttonStyle(.bordered)
                            .help("Move port \(runtime.config.port.map(String.init) ?? "") to \(runtime.projectName) / \(runtime.config.name)")
                        }

                        Button {
                            openActivityMonitor()
                        } label: {
                            Label("Open Activity Monitor", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let pid = diagnostic.processID {
                        Spacer()
                        Text("PID \(pid)")
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
    }

    private func externalProcess(for diagnostic: MemoryDiagnostic) -> ExternalProcessSnapshot? {
        guard diagnostic.serverID == nil, let pid = diagnostic.processID else { return nil }
        return externalProcesses.first { $0.pid == pid }
    }

    private func externalProcessDetails(_ process: ExternalProcessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("Outside Portly", systemImage: "arrow.up.right.square")
                Spacer()
                Text("Footprint \(bytes(process.memoryBytes)) · RAM \(bytes(process.residentMemoryBytes))")
                    .monospacedDigit()
            }
            .font(PortlyTypography.metadata)

            Text(process.command)
                .font(PortlyTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(process.command)
                .textSelection(.enabled)
                .clipped()

            if process.terminationPID != process.pid {
                Text("Stop target: PID \(process.terminationPID) · \(process.terminationCommand)")
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(process.terminationCommand)
                    .textSelection(.enabled)
                    .clipped()
            } else if let parent = process.parentCommand {
                Text("Parent PID \(process.parentPID) · \(parent)")
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(parent)
                    .textSelection(.enabled)
                    .clipped()
            }

            HStack(spacing: 12) {
                if let directory = process.workingDirectory {
                    Label(directory, systemImage: "folder")
                        .lineLimit(1)
                        .help(directory)
                }
                if !process.listeningPorts.isEmpty {
                    Label(
                        process.listeningPorts.map { ":\($0)" }.joined(separator: ", "),
                        systemImage: "network"
                    )
                } else {
                    Label("No listening port · cannot be moved as a server", systemImage: "network.slash")
                }
            }
            .font(PortlyTypography.metadata)
            .foregroundStyle(.secondary)

            Text("Footprint is memory still owned, including compressed or swapped pages. RAM is what is resident right now.")
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipped()
    }

    private func migrationRuntime(for process: ExternalProcessSnapshot) -> ServerRuntime? {
        for port in process.listeningPorts {
            if let runtime = supervisor.runtimes.values.first(where: {
                $0.config.port == port && !$0.isRunning
            }) {
                return runtime
            }
        }
        return nil
    }

    private var externalStopTitle: String {
        guard let process = pendingExternalStop else { return "Stop process?" }
        return process.terminationPID == process.pid ? "Stop \(process.displayName)?" : "Stop parent dev session?"
    }

    private func externalStopMessage(_ process: ExternalProcessSnapshot) -> String {
        let scope = process.terminationPID == process.pid
            ? "PID \(process.pid)"
            : "PID \(process.terminationPID) and its child processes"
        return "Portly will revalidate the command, then send SIGTERM to \(scope). It never sends SIGKILL automatically. Target: \(process.terminationCommand)"
    }

    private func stopExternalProcess(_ process: ExternalProcessSnapshot) {
        pendingExternalStop = nil
        stoppingProcessIDs.insert(process.terminationPID)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ExternalProcessController.stop(process)
            }.value
            if case .failure(let error) = result {
                processActionError = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(1))
            stoppingProcessIDs.remove(process.terminationPID)
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
            title: "Managed memory history",
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
                let dashByProjectID = Dictionary(
                    uniqueKeysWithValues: styles.map { ($0.id, $0.dash) }
                )

                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        // Ordered like the lines themselves, biggest first, so the
                        // legend can be read top-down instead of matched by color.
                        ForEach(legendOrder(for: styles), id: \.style.id) { entry in
                            seriesLegend(
                                entry.style.name,
                                detail: entry.footprintBytes.map(bytes),
                                color: Color(hex: entry.style.colorHex),
                                dash: entry.style.dash
                            )
                        }
                    }

                    Chart(history) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Footprint", gibibytes(point.footprintBytes)),
                            series: .value("Project", point.projectID)
                        )
                        .foregroundStyle(by: .value("Project", point.projectID))
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: dashByProjectID[point.projectID] ?? []
                            )
                        )
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
            VStack(alignment: .leading, spacing: 14) {
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
    }

    private var processes: some View {
        dashboardSection(
            title: "Managed processes",
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

    private var outsidePortlyProcesses: some View {
        dashboardSection(
            title: "Top processes outside Portly",
            subtitle: "Current user only · top 20 by resident RAM · never stopped automatically"
        ) {
            Table(externalProcesses) {
                TableColumn("Process") { process in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(process.displayName)
                            .font(PortlyTypography.bodyMedium)
                            .lineLimit(1)
                        Text(process.command)
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(process.command)
                    }
                }
                .width(min: 210, ideal: 320)

                TableColumn("PID") { process in
                    Text(String(process.pid)).monospacedDigit()
                }
                .width(min: 54, ideal: 64)

                TableColumn("CPU") { process in
                    Text(process.cpuPercent.formatted(.number.precision(.fractionLength(1))) + "%")
                        .monospacedDigit()
                }
                .width(min: 64, ideal: 76)

                TableColumn("Footprint") { process in
                    Text(bytes(process.memoryBytes)).monospacedDigit()
                }
                .width(min: 86, ideal: 100)

                TableColumn("Resident") { process in
                    Text(bytes(process.residentMemoryBytes)).monospacedDigit()
                }
                .width(min: 86, ideal: 100)

                TableColumn("Likely fix") { process in
                    Text(MemoryDiagnosticsEngine.advice(for: process.command, managed: false))
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(MemoryDiagnosticsEngine.advice(for: process.command, managed: false))
                }
                .width(min: 240, ideal: 360)
            }
            .font(PortlyTypography.body)
            .frame(minHeight: 340, idealHeight: 420, maxHeight: 520)
            .accessibilityLabel("Processes outside Portly")
        }
    }

    private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
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

    /// Legend entry for a multi-series chart: the swatch repeats the line's dash so
    /// the pattern is learnable, and the current value removes the color matching.
    private func seriesLegend(
        _ title: String,
        detail: String?,
        color: Color,
        dash: [CGFloat]
    ) -> some View {
        HStack(spacing: 7) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 18, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
            .frame(width: 18, height: 2)
            .accessibilityHidden(true)

            Text(title)
                .font(PortlyTypography.bodyMedium)
                .lineLimit(1)

            if let detail {
                Text(detail)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    /// Biggest footprint first, then the projects that only survive in history.
    private func legendOrder(
        for styles: [DashboardProjectChartStyle]
    ) -> [(style: DashboardProjectChartStyle, footprintBytes: UInt64?)] {
        let footprints = Dictionary(
            projectRows.map { ($0.id, $0.footprintBytes) },
            uniquingKeysWith: { first, _ in first }
        )
        return styles
            .map { (style: $0, footprintBytes: footprints[$0.id]) }
            .sorted { lhs, rhs in
                switch (lhs.footprintBytes, rhs.footprintBytes) {
                case let (left?, right?) where left != right:
                    return left > right
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                default:
                    return lhs.style.name.localizedStandardCompare(rhs.style.name) == .orderedAscending
                }
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
    /// Second encoding channel, so series stay separable when two projects share a
    /// color and for anyone who cannot tell the two hues apart. Empty means solid.
    let dash: [CGFloat]
}

enum DashboardProjectChartStyleScale {
    /// Cycled alongside the color so every series carries a shape as well as a hue.
    static let dashPatterns: [[CGFloat]] = [[], [6, 3], [1.5, 3], [9, 3, 1.5, 3]]

    static func make(
        history: [ProjectResourceHistoryPoint],
        activeProjects: [(id: String, name: String, colorHex: String)]
    ) -> [DashboardProjectChartStyle] {
        var namesByID: [String: (name: String, colorHex: String)] = [:]

        for point in history {
            namesByID[point.projectID] = (point.projectName, point.colorHex)
        }

        // Current configuration wins when a project was renamed or recolored,
        // while stopped projects remain in the domain until their history ages out.
        for project in activeProjects {
            namesByID[project.id] = (project.name, project.colorHex)
        }

        // Sorted by name, not by footprint, so a project keeps the same dash pattern
        // as the numbers move underneath it.
        let ordered = namesByID.sorted { lhs, rhs in
            let nameOrder = lhs.value.name.localizedStandardCompare(rhs.value.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.key < rhs.key
        }

        return ordered.enumerated().map { index, entry in
            DashboardProjectChartStyle(
                id: entry.key,
                name: entry.value.name,
                colorHex: entry.value.colorHex,
                dash: dashPatterns[index % dashPatterns.count]
            )
        }
    }
}
