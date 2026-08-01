import AppKit
import PortlyCore
import SwiftUI

struct MainView: View {
    enum Selection: Hashable {
        case ports
        case project(String)
        case server(String)
    }

    @EnvironmentObject private var supervisor: Supervisor
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var appSelection = AppSelection.shared
    @State private var selection: Selection?
    @State private var editingProject: Project?
    @State private var editingServer: EditingServer?
    @State private var addingProject = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .onAppear {
            WindowOpener.opener = { openWindow(id: WindowOpener.mainWindowID) }
            applyPendingSelection()
        }
        .onChange(of: appSelection.pending) { applyPendingSelection() }
        .sheet(isPresented: $addingProject) {
            ProjectForm(project: nil) { name, root, icon, color in
                let project = supervisor.addProject(name: name, root: root, icon: icon, color: color)
                selection = .project(project.id)
            }
        }
        .sheet(item: $editingProject) { project in
            ProjectForm(project: project) { name, root, icon, color in
                var updated = project
                updated.name = name
                updated.root = root
                updated.icon = icon
                updated.color = color
                supervisor.updateProject(updated)
            }
        }
        .sheet(item: $editingServer) { editing in
            ServerForm(server: editing.server, projectName: editing.projectName, projectRoot: editing.projectRoot) { result in
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
            ForEach(sidebarProjects) { project in
                Section {
                    ProjectHeader(project: project)
                        .tag(Selection.project(project.id))
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
        .safeAreaInset(edge: .bottom) { sidebarActions }
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

    private var sidebarActions: some View {
        VStack(spacing: 6) {
            Button {
                addingProject = true
            } label: {
                Label("Add Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                selection = .ports
            } label: {
                HStack {
                    Label("View Ports", systemImage: "network")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selection == .ports ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055))
            }
            .accessibilityHint("Shows every listening TCP port on this Mac")
        }
        .font(PortlyTypography.bodyMedium)
        .padding(10)
        .background(.bar)
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

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .ports:
            PortsView()
        case .server(let id):
            if let runtime = supervisor.runtime(for: id) {
                ServerDetail(runtime: runtime) {
                    if let project = supervisor.project(containing: id) {
                        editingServer = EditingServer(projectID: project.id, projectName: project.name, projectRoot: project.root, server: runtime.config)
                    }
                }
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
            emptyDetail(supervisor.projects.isEmpty
                ? "Add a project to get started."
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
                if let port = runtime.config.port {
                    Text("localhost:\(String(port))")
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                }
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
            if runtime.isRunning {
                Button { runtime.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless)
            } else {
                Button { runtime.start() } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onSelect)
    }
}
