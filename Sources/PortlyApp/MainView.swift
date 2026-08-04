import AppKit
import PortlyCore
import SwiftUI

struct MainView: View {
    enum Selection: Hashable {
        case resources
        case ports
        case project(String)
        case server(String)
    }

    @EnvironmentObject private var supervisor: Supervisor
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var appSelection = AppSelection.shared
    @StateObject private var agentSetup = AgentSetup()
    @AppStorage("agentOnboardingDismissed") private var agentOnboardingDismissed = false
    @State private var selection: Selection?
    @State private var editingProject: Project?
    @State private var editingServer: EditingServer?
    @State private var addingProject = false
    @State private var runningTemporary = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !agentOnboardingDismissed {
                        AgentOnboardingCard(setup: agentSetup) {
                            agentOnboardingDismissed = true
                        }
                    }
                }
        }
        .onAppear {
            WindowOpener.opener = { openWindow(id: WindowOpener.mainWindowID) }
            agentSetup.refresh()
            applyPendingSelection()
        }
        .onChange(of: appSelection.pending) { applyPendingSelection() }
        .onChange(of: supervisor.revision) { clearFinishedTemporarySelection() }
        .sheet(isPresented: $addingProject) {
            ProjectForm(
                project: nil,
                takenColors: supervisor.projects.map(\.color)
            ) { name, root, icon, color in
                let project = supervisor.addProject(
                    name: name,
                    root: root,
                    icon: icon,
                    color: color
                )
                selection = .project(project.id)
            }
        }
        .sheet(isPresented: $runningTemporary) {
            TemporaryProcessForm { name, command, directory, port, healthURL, timeoutSeconds in
                let runtime = supervisor.runTemporary(
                    name: name,
                    command: command,
                    directory: directory,
                    port: port,
                    healthURL: healthURL,
                    timeoutSeconds: timeoutSeconds
                )
                selection = .server(runtime.id)
            }
        }
        .sheet(item: $editingProject) { project in
            ProjectForm(
                project: project,
                takenColors: supervisor.projects.filter { $0.id != project.id }.map(\.color)
            ) { name, root, icon, color in
                var updated = project
                updated.name = name
                updated.root = root
                updated.icon = icon
                updated.color = color
                supervisor.updateProject(updated)
            }
        }
        .sheet(item: $editingServer) { editing in
            ServerForm(
                server: editing.server,
                projectID: editing.projectID,
                projectName: editing.projectName,
                projectRoot: editing.projectRoot
            ) { result, memoryLimitMode, memoryLimitBytes in
                supervisor.updateProjectMemoryLimit(
                    projectID: editing.projectID,
                    mode: memoryLimitMode,
                    bytes: memoryLimitBytes
                )
                if let existing = editing.server, existing.id == result.id {
                    supervisor.updateServer(result)
                } else {
                    supervisor.addServer(projectID: editing.projectID, server: result)
                    selection = .server(result.id)
                }
            }
        }
        .font(PortlyTypography.body)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if !supervisor.visibleTemporaryRuntimes.isEmpty {
                Section {
                    ForEach(supervisor.visibleTemporaryRuntimes, id: \.id) { runtime in
                        ServerRow(runtime: runtime)
                            .tag(Selection.server(runtime.id))
                            .contextMenu { temporaryServerMenu(runtime) }
                    }
                } header: {
                    Label("Temporary", systemImage: "clock.badge")
                        .help("Supervised background jobs currently running with a timeout")
                }
            }

            ForEach(sidebarProjects) { project in
                Section {
                    ProjectHeader(project: project)
                        .tag(Selection.project(project.id))
                        .onTapGesture(count: 2) { openProject(project) }
                        .contextMenu { projectMenu(project) }

                    ForEach(project.servers) { server in
                        if let runtime = supervisor.runtime(for: server.id) {
                            ServerRow(runtime: runtime)
                                .padding(.leading, 14)
                                .tag(Selection.server(server.id))
                                .contextMenu { serverMenu(runtime, project: project) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Running projects float to the top, so rows change place on their own.
        // Letting them travel keeps the list readable instead of teleporting.
        .animation(Motion.reorder, value: runningSignature)
        .safeAreaInset(edge: .bottom) { sidebarActions }
    }

    /// Changes exactly when the running/idle split changes, which is what drives
    /// the sidebar order — not on every uptime tick.
    private var runningSignature: String {
        supervisor.projects
            .map { projectIsRunning($0) ? "1" : "0" }
            .joined()
    }

    private var sidebarProjects: [Project] {
        supervisor.projects.enumerated()
            .sorted { lhs, rhs in
                let lhsIsRunning = projectIsRunning(lhs.element)
                let rhsIsRunning = projectIsRunning(rhs.element)

                if lhsIsRunning != rhsIsRunning {
                    return lhsIsRunning
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func projectIsRunning(_ project: Project) -> Bool {
        project.servers.contains { server in
            supervisor.runtime(for: server.id)?.isRunning == true
        }
    }

    private func openProject(_ project: Project) {
        guard let url = project.servers
            .compactMap({ supervisor.runtime(for: $0.id)?.url })
            .first,
            let link = URL(string: url)
        else { return }

        NSWorkspace.shared.open(link)
    }

    private var sidebarActions: some View {
        VStack(spacing: 6) {
            sidebarDestinationButton(
                title: "Resources",
                systemImage: "chart.xyaxis.line",
                selection: .resources,
                hint: "Shows live memory, smart diagnostics, safe fixes, and heavy processes inside or outside Portly"
            )

            sidebarDestinationButton(
                title: "View Ports",
                systemImage: "network",
                selection: .ports,
                hint: "Shows every listening TCP port on this Mac"
            )

            Button {
                runningTemporary = true
            } label: {
                Label("Run Temporary…", systemImage: "clock.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Run temporary process")
            .accessibilityHint("For small previews and one-off work that should not create a permanent project")

            Button {
                addingProject = true
            } label: {
                Label("Add Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Add project")

        }
        .font(PortlyTypography.bodyMedium)
        .padding(10)
        .background(.bar)
    }

    private func sidebarDestinationButton(
        title: String,
        systemImage: String,
        selection destination: Selection,
        hint: String
    ) -> some View {
        Button {
            selection = destination
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(self.selection == destination ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055))
        }
        .accessibilityHint(hint)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("Start All") { supervisor.startProject(project.id) }
        Button("Stop All") { supervisor.stopProject(project.id) }
        Divider()
        Button("Add Server…") {
            editingServer = EditingServer(projectID: project.id, projectName: project.name, projectRoot: project.root, server: nil)
        }
        Button("Edit Project…") { editingProject = project }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSString(string: project.root).expandingTildeInPath)
        }
        Divider()
        Button("Remove Project") { supervisor.removeProject(id: project.id) }
    }

    @ViewBuilder
    private func serverMenu(_ runtime: ServerRuntime, project: Project) -> some View {
        if runtime.isRunning {
            Button("Stop") { runtime.stop() }
            Button("Restart") { runtime.restart() }
        } else {
            Button("Start") { runtime.start() }
        }
        Divider()
        if let url = runtime.url {
            Button("Open \(url)") {
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
            }
        }
        Button("Edit…") {
            editingServer = EditingServer(projectID: project.id, projectName: project.name, projectRoot: project.root, server: runtime.config)
        }
        Divider()
        Button("Remove Server") { supervisor.removeServer(id: runtime.id) }
    }

    @ViewBuilder
    private func temporaryServerMenu(_ runtime: ServerRuntime) -> some View {
        if runtime.isRunning {
            Button("Stop and Remove") { supervisor.removeServer(id: runtime.id) }
            Button("Restart") { runtime.restart() }
        } else if runtime.state == .failed {
            Button("Retry") { runtime.start() }
            Divider()
            Button("Remove") { supervisor.removeServer(id: runtime.id) }
        } else {
            Button("Run Again") { runtime.start() }
            Divider()
            Button("Remove") { supervisor.removeServer(id: runtime.id) }
        }
        if let url = runtime.url {
            Divider()
            Button("Open \(url)") {
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .resources:
            ResourceDashboard()
        case .ports:
            PortsView()
        case .server(let id):
            if let runtime = supervisor.runtime(for: id) {
                ServerDetail(
                    runtime: runtime,
                    onEdit: supervisor.temporaryRuntimeIDs.contains(id) ? nil : {
                        if let project = supervisor.project(containing: id) {
                            editingServer = EditingServer(
                                projectID: project.id,
                                projectName: project.name,
                                projectRoot: project.root,
                                server: runtime.config
                            )
                        }
                    }
                )
            } else {
                emptyDetail("This server no longer exists.")
            }
        case .project(let id):
            if let project = supervisor.projects.first(where: { $0.id == id }) {
                ProjectDetail(project: project) {
                    editingServer = EditingServer(projectID: project.id, projectName: project.name, projectRoot: project.root, server: nil)
                } onEdit: {
                    editingProject = project
                } onSelectServer: { serverID in
                    selection = .server(serverID)
                }
            } else {
                emptyDetail("This project no longer exists.")
            }
        case nil:
            emptyDetail(supervisor.projects.isEmpty && supervisor.visibleTemporaryRuntimes.isEmpty
                ? "Run a temporary process or add a project to get started."
                : "Select a server to see its terminal.")
        }
    }

    private func emptyDetail(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clearFinishedTemporarySelection() {
        guard case .server(let id) = selection,
              supervisor.temporaryRuntimeIDs.contains(id),
              supervisor.runtime(for: id)?.isRunning == false else { return }
        selection = nil
    }

    private func applyPendingSelection() {
        guard let pending = appSelection.pending else { return }
        selection = pending
        appSelection.pending = nil
    }

    struct EditingServer: Identifiable {
        let projectID: String
        let projectName: String
        let projectRoot: String
        let server: ServerConfig?
        var id: String { (server?.id ?? "new") + projectID }
    }
}

// MARK: - Sidebar rows

private struct ProjectHeader: View {
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(hex: project.color))
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(hex: project.color).opacity(0.12))
                }
            Text(project.name)
                .font(PortlyTypography.project)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct ServerRow: View {
    @ObservedObject var runtime: ServerRuntime

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: runtime.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(runtime.config.name)
                    .font(PortlyTypography.bodyMedium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let port = runtime.config.port {
                        Text("localhost:\(String(port))")
                    }
                    if let job = runtime.temporaryJobStatus {
                        Text(jobLabel(job))
                    }
                    if let metrics = runtime.processMetrics {
                        Spacer(minLength: 4)
                        Image(systemName: "memorychip")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(metrics.memoryPressure.color)
                            .help(
                                "Footprint: \(memoryText(metrics)) — \(metrics.memoryPressure.label). "
                                    + "Open the server for full resource details."
                            )
                            .accessibilityLabel(
                                "Memory footprint \(memoryText(metrics)), \(metrics.memoryPressure.label) use"
                            )
                    }
                }
                .font(PortlyTypography.metadata)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let startedAt = runtime.startedAt, runtime.isRunning {
                Text(startedAt.compactUptime)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
    }

    private func memoryText(_ metrics: ProcessMetrics) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(metrics.memoryBytes), countStyle: .memory)
    }

    private func jobLabel(_ job: TemporaryJobStatus) -> String {
        switch job.state {
        case .running: return "timeout \(TemporaryTimeout.display(job.timeoutSeconds))"
        case .succeeded: return "succeeded"
        case .failed: return job.exitCode.map { "failed (exit \($0))" } ?? "failed"
        case .timedOut: return "timed out"
        case .stopped: return "stopped"
        }
    }
}

// MARK: - Project detail

private struct ProjectDetail: View {
    let project: Project
    let onAddServer: () -> Void
    let onEdit: () -> Void
    let onSelectServer: (String) -> Void

    @EnvironmentObject private var supervisor: Supervisor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: project.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Color(hex: project.color))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(PortlyTypography.title)
                    Text(NSString(string: project.root).abbreviatingWithTildeInPath)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            if project.servers.isEmpty {
                VStack(spacing: 10) {
                    Text("No servers in this project yet.")
                        .foregroundStyle(.secondary)
                    Button("Add Server…", action: onAddServer)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(project.servers) { server in
                        if let runtime = supervisor.runtime(for: server.id) {
                            ProjectServerRow(runtime: runtime) { onSelectServer(server.id) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    supervisor.startProject(project.id)
                } label: {
                    Label("Start All", systemImage: "play.fill")
                }
                .help("Start every server in this project")

                Button {
                    supervisor.stopProject(project.id)
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .help("Stop every server in this project")

                Button(action: onAddServer) {
                    Label("Add Server", systemImage: "plus")
                }

                Button(action: onEdit) {
                    Label("Edit Project", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle(project.name)
    }
}

private struct ProjectServerRow: View {
    @ObservedObject var runtime: ServerRuntime
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: runtime.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.config.name)
                    .font(PortlyTypography.bodyMedium)
                Text(runtime.config.command)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(runtime.state.label)
                .font(PortlyTypography.label)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(Motion.state, value: runtime.state)
            StartStopButton(runtime: runtime)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onSelect)
    }
}
