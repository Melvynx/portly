import AppKit
import PortlyCore
import SwiftUI

struct PortsView: View {
    @EnvironmentObject private var supervisor: Supervisor
    @StateObject private var model = ActivePortsModel()
    @State private var search = ""
    @State private var pendingTermination: ActivePort?

    private var groups: [ActivePortGroup] {
        model.filteredGroups(matching: search)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.isLoading && model.groups.isEmpty {
                ProgressView("Scanning listening ports…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error, model.groups.isEmpty {
                ContentUnavailableView {
                    Label("Unable to scan ports", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Scan again") { refresh() }
                }
            } else if model.groups.isEmpty {
                ContentUnavailableView {
                    Label("No active ports", systemImage: "network.slash")
                } description: {
                    Text("No TCP processes are listening on this Mac.")
                }
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(groups) { group in
                            if group.isSystem {
                                SystemPortsCard(
                                    group: group,
                                    revealForSearch: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                )
                            } else {
                                PortGroupCard(
                                    group: group,
                                    onOpen: open,
                                    onStop: requestStop
                                )
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .navigationTitle("Ports")
        .task {
            while !Task.isCancelled {
                await model.refresh(using: supervisor)
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: supervisor.revision) {
            refresh()
        }
        .confirmationDialog(
            terminationTitle,
            isPresented: Binding(
                get: { pendingTermination != nil },
                set: { if !$0 { pendingTermination = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingTermination
        ) { port in
            Button("Terminate \(port.applicationName)", role: .destructive) {
                Task { await model.stop(port, using: supervisor) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { port in
            Text("This sends SIGTERM to process \(String(port.pid)). Every port opened by that process will close.")
        }
        .alert("Unable to stop process", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "The process could not be stopped.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "network")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Active ports")
                    .font(.system(size: 20, weight: .semibold))
                Text(model.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            TextField("Search ports", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoading)
            .accessibilityLabel("Refresh ports")
            .help("Refresh ports")
        }
        .padding(16)
    }

    private var terminationTitle: String {
        guard let port = pendingTermination else { return "Terminate process?" }
        return "Terminate \(port.applicationName)?"
    }

    private func refresh() {
        Task { await model.refresh(using: supervisor) }
    }

    private func open(_ port: ActivePort) {
        guard port.canOpen else { return }
        guard let url = URL(string: "http://localhost:\(String(port.port))") else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestStop(_ port: ActivePort) {
        switch port.kind {
        case .managed:
            Task { await model.stop(port, using: supervisor) }
        case .external:
            pendingTermination = port
        case .portly, .system:
            break
        }
    }
}

private struct SystemPortsCard: View {
    let group: ActivePortGroup
    let revealForSearch: Bool
    @State private var showsPorts = false

    private var isExpanded: Bool { showsPorts || revealForSearch }

    private var applications: [String] {
        Array(Set(group.ports.map(\.applicationName)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                showsPorts.toggle()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                        Image(systemName: "gearshape.2")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("System")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Protected background services · Read only")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(systemSummary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide System ports" : "Show System ports")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                ForEach(applications, id: \.self) { application in
                    Divider().padding(.leading, 50)
                    systemApplication(application)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 6, y: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private var systemSummary: String {
        "\(applications.count) \(applications.count == 1 ? "service" : "services") · \(group.ports.count) ports"
    }

    private func ports(for application: String) -> [ActivePort] {
        group.ports
            .filter { $0.applicationName == application }
            .sorted { $0.port < $1.port }
    }

    private func systemApplication(_ application: String) -> some View {
        let ports = ports(for: application)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(application)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(ports.count) \(ports.count == 1 ? "port" : "ports")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                if index > 0 {
                    Divider().padding(.leading, 50)
                }
                SystemPortRow(port: port)
            }
        }
    }
}

private struct SystemPortRow: View {
    let port: ActivePort

    var body: some View {
        HStack(spacing: 10) {
            Text(":\(String(port.port))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(port.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text("Protected")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Text(port.processDetail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Protected system listener")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct PortGroupCard: View {
    let group: ActivePortGroup
    let onOpen: (ActivePort) -> Void
    let onStop: (ActivePort) -> Void
    @State private var showsOtherPorts = false

    private var primaryPorts: [ActivePort] {
        group.ports.filter { !$0.isOtherPort }
    }

    private var otherPorts: [ActivePort] {
        group.ports.filter(\.isOtherPort)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: group.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(group.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold))
                    if !group.detail.isEmpty {
                        Text(group.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text(group.summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().padding(.leading, 41)

            ForEach(Array(primaryPorts.enumerated()), id: \.element.id) { index, port in
                PortRow(port: port, onOpen: onOpen, onStop: onStop)
                if index < primaryPorts.count - 1 {
                    Divider().padding(.leading, 41)
                }
            }

            if !otherPorts.isEmpty {
                if !primaryPorts.isEmpty {
                    Divider().padding(.leading, 41)
                }

                Button {
                    showsOtherPorts.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showsOtherPorts ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text(otherPortsDisclosureLabel)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("Same process")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsOtherPorts ? "Expanded" : "Collapsed")

                if showsOtherPorts {
                    Divider().padding(.leading, 41)
                    ForEach(Array(otherPorts.enumerated()), id: \.element.id) { index, port in
                        PortRow(port: port, onOpen: onOpen, onStop: onStop)
                        if index < otherPorts.count - 1 {
                            Divider().padding(.leading, 41)
                        }
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.055), radius: 8, y: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private var otherPortsDisclosureLabel: String {
        let count = otherPorts.count
        return "\(count) other \(count == 1 ? "port" : "ports")"
    }
}

private struct PortRow: View {
    let port: ActivePort
    let onOpen: (ActivePort) -> Void
    let onStop: (ActivePort) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(":\(String(port.port))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(port.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    PortKindBadge(port: port)
                }
                Text(port.processDetail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 10)

            if port.canOpen {
                Button { onOpen(port) } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open localhost port \(String(port.port))")
                .help("Open localhost:\(String(port.port))")
            }

            if port.canStop {
                Button { onStop(port) } label: {
                    Image(systemName: port.kind == .managed ? "stop.fill" : "xmark")
                        .foregroundStyle(port.kind == .external ? Color.red : Color.primary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(port.kind == .managed ? "Stop \(port.displayName)" : "Terminate \(port.applicationName)")
                .help(port.kind == .managed ? "Stop server" : "Terminate process")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct PortKindBadge: View {
    let port: ActivePort

    var body: some View {
        Text(port.badgeLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(port.badgeForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(port.badgeForeground.opacity(0.12), in: Capsule())
    }
}

struct ActivePort: Identifiable, Hashable {
    enum Kind: Int, Hashable {
        case managed
        case portly
        case external
        case system

        var label: String {
            switch self {
            case .managed: return "Managed"
            case .portly: return "Portly"
            case .external: return "External"
            case .system: return "Protected"
            }
        }

        var foreground: Color {
            switch self {
            case .managed: return .green
            case .portly: return .blue
            case .external: return .secondary
            case .system: return .secondary
            }
        }

        var background: Color { foreground.opacity(0.12) }
    }

    let id: String
    let port: Int
    let pid: Int32
    let command: String
    let user: String
    let workingDirectory: String?
    let applicationName: String
    let displayName: String
    let kind: Kind
    let serverID: String?
    var isPrimaryPort: Bool

    var isOtherPort: Bool {
        !isPrimaryPort && (kind == .managed || kind == .external)
    }

    var canOpen: Bool {
        !isOtherPort && (kind == .managed || kind == .external)
    }

    var canStop: Bool {
        !isOtherPort && (kind == .managed || kind == .external)
    }

    var badgeLabel: String {
        isOtherPort ? "Other port" : kind.label
    }

    var badgeForeground: Color {
        isOtherPort ? .secondary : kind.foreground
    }

    var processDetail: String {
        var parts = [command, "PID \(pid)"]
        if !user.isEmpty { parts.append(user) }
        return parts.joined(separator: " · ")
    }
}

struct ActivePortGroup: Identifiable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    let color: Color
    let rank: Int
    var ports: [ActivePort]

    var isSystem: Bool { id == "system" }

    var summary: String {
        let managedServers = Set(ports.filter { $0.kind == .managed }.compactMap(\.serverID)).count
        let otherPorts = ports.filter(\.isOtherPort).count
        let external = Set(ports.filter { $0.kind == .external }.map(\.pid)).count
        let system = ports.filter { $0.kind == .system || $0.kind == .portly }.count

        var parts: [String] = []
        if managedServers > 0 {
            parts.append("\(managedServers) \(managedServers == 1 ? "server" : "servers")")
        }
        if external > 0 {
            parts.append("\(external) external \(external == 1 ? "app" : "apps")")
        }
        if otherPorts > 0 {
            parts.append("\(otherPorts) other \(otherPorts == 1 ? "port" : "ports")")
        }
        if system > 0 {
            parts.append("\(system) system")
        }
        if parts.isEmpty {
            parts.append("\(ports.count) \(ports.count == 1 ? "port" : "ports")")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class ActivePortsModel: ObservableObject {
    @Published private(set) var groups: [ActivePortGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published var actionError: String?

    private var refreshGeneration = 0

    var summary: String {
        let ports = groups.flatMap(\.ports)
        let managed = Set(ports.filter { $0.kind == .managed }.compactMap(\.serverID)).count
        let otherPorts = ports.filter(\.isOtherPort).count
        let external = Set(ports.filter { $0.kind == .external }.map(\.pid)).count
        let system = ports.filter { $0.kind == .system || $0.kind == .portly }.count
        if ports.isEmpty { return "No listening TCP ports" }
        var parts = ["\(String(ports.count)) listening", "\(String(managed)) managed servers"]
        parts.append("\(String(external)) external \(external == 1 ? "app" : "apps")")
        if otherPorts > 0 {
            parts.append("\(String(otherPorts)) other \(otherPorts == 1 ? "port" : "ports")")
        }
        parts.append("\(String(system)) system")
        return parts.joined(separator: " · ")
    }

    func filteredGroups(matching query: String) -> [ActivePortGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let matchesGroup = group.name.lowercased().contains(needle)
                || group.detail.lowercased().contains(needle)
            let ports = group.ports.filter { port in
                matchesGroup
                    || String(port.port).contains(needle)
                    || String(port.pid).contains(needle)
                    || port.displayName.lowercased().contains(needle)
                    || port.command.lowercased().contains(needle)
            }
            guard !ports.isEmpty else { return nil }
            var filtered = group
            filtered.ports = ports
            return filtered
        }
    }

    func refresh(using supervisor: Supervisor) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true

        let listeners = await Task.detached(priority: .userInitiated) {
            PortInspector.listeners()
        }.value
        guard generation == refreshGeneration else { return }

        groups = makeGroups(from: listeners, supervisor: supervisor)
        error = nil
        isLoading = false
    }

    func stop(_ port: ActivePort, using supervisor: Supervisor) async {
        switch port.kind {
        case .managed:
            guard let serverID = port.serverID, let runtime = supervisor.runtime(for: serverID) else {
                actionError = "Portly could not find the managed server for port \(port.port)."
                return
            }
            runtime.stop()
        case .external:
            let stopped = await Task.detached(priority: .userInitiated) {
                PortInspector.kill(pid: port.pid)
            }.value
            if !stopped {
                actionError = "Process \(port.pid) did not accept the stop request. Check its permissions and try again."
                return
            }
        case .portly, .system:
            return
        }

        try? await Task.sleep(for: .milliseconds(350))
        await refresh(using: supervisor)
    }

    private func makeGroups(from listeners: [PortInspector.Listener], supervisor: Supervisor) -> [ActivePortGroup] {
        let projects = supervisor.projects
        let managed = projects.flatMap { project in
            project.servers.compactMap { server -> (Project, ServerRuntime)? in
                guard let runtime = supervisor.runtime(for: server.id), runtime.isRunning else { return nil }
                return (project, runtime)
            }
        }

        // A managed dev server often opens a second, ephemeral listener from
        // the same child process (for example Vite's internal tooling). The
        // runtime PID belongs to the parent shell, so learn the actual listener
        // PID from the configured port before classifying the remaining ports.
        var managedProcesses: [Int32: (Project, ServerRuntime)] = [:]
        for (project, runtime) in managed {
            guard let configuredPort = runtime.config.port else { continue }
            for listener in listeners where listener.port == configuredPort {
                managedProcesses[listener.pid] = (project, runtime)
            }
        }

        var result: [String: ActivePortGroup] = [:]
        for listener in listeners {
            let projectByPath = listener.workingDirectory.flatMap { directory in
                projects.first { isPath(directory, inside: $0.root) }
            }
            let exactManagedHit = managed.first { _, runtime in
                runtime.config.port == listener.port || runtime.status.pid == listener.pid
            }
            let managedHit = exactManagedHit ?? managedProcesses[listener.pid]

            let port: ActivePort
            let group: ActivePortGroup
            if let (project, runtime) = managedHit {
                let isPrimaryPort = runtime.config.port == listener.port
                port = ActivePort(
                    id: listener.id,
                    port: listener.port,
                    pid: listener.pid,
                    command: listener.command,
                    user: listener.user,
                    workingDirectory: listener.workingDirectory,
                    applicationName: project.name,
                    displayName: isPrimaryPort ? runtime.config.name : "Auxiliary listener",
                    kind: .managed,
                    serverID: runtime.id,
                    isPrimaryPort: isPrimaryPort
                )
                group = projectGroup(project, rank: projectRank(project, in: projects))
            } else if listener.pid == getpid(), listener.port == supervisor.settings.apiPort {
                port = ActivePort(
                    id: listener.id,
                    port: listener.port,
                    pid: listener.pid,
                    command: listener.command,
                    user: listener.user,
                    workingDirectory: listener.workingDirectory,
                    applicationName: "Portly",
                    displayName: "Control API",
                    kind: .portly,
                    serverID: nil,
                    isPrimaryPort: true
                )
                group = ActivePortGroup(
                    id: "system",
                    name: "System",
                    detail: "Protected background services",
                    icon: "gearshape.2",
                    color: .secondary,
                    rank: 10_000,
                    ports: []
                )
            } else if let project = projectByPath {
                port = externalPort(listener, applicationName: project.name)
                group = projectGroup(project, rank: projectRank(project, in: projects))
            } else {
                let name = applicationName(for: listener)
                port = systemPort(listener, applicationName: name)
                group = ActivePortGroup(
                    id: "system",
                    name: "System",
                    detail: "Protected background services",
                    icon: "gearshape.2",
                    color: .secondary,
                    rank: 10_000,
                    ports: []
                )
            }

            var populated = result[group.id] ?? group
            if !populated.ports.contains(where: { $0.id == port.id }) {
                populated.ports.append(port)
            }
            result[group.id] = populated
        }

        return result.values
            .map { group in
                var sorted = group
                let externalProcesses = Dictionary(grouping: sorted.ports.indices.filter {
                    sorted.ports[$0].kind == .external
                }) { index in
                    sorted.ports[index].pid
                }
                for indices in externalProcesses.values where indices.count > 1 {
                    guard let primaryIndex = indices.min(by: {
                        sorted.ports[$0].port < sorted.ports[$1].port
                    }) else { continue }
                    for index in indices {
                        sorted.ports[index].isPrimaryPort = index == primaryIndex
                    }
                }
                sorted.ports.sort { lhs, rhs in
                    if lhs.isPrimaryPort != rhs.isPrimaryPort { return lhs.isPrimaryPort }
                    return lhs.port < rhs.port
                }
                return sorted
            }
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
                return lhs.rank < rhs.rank
            }
    }

    private func projectGroup(_ project: Project, rank: Int) -> ActivePortGroup {
        ActivePortGroup(
            id: "project:\(project.id)",
            name: project.name,
            detail: NSString(string: project.root).abbreviatingWithTildeInPath,
            icon: project.icon,
            color: Color(hex: project.color),
            rank: rank,
            ports: []
        )
    }

    private func projectRank(_ project: Project, in projects: [Project]) -> Int {
        projects.firstIndex(where: { $0.id == project.id }) ?? projects.count
    }

    private func externalPort(_ listener: PortInspector.Listener, applicationName: String) -> ActivePort {
        ActivePort(
            id: listener.id,
            port: listener.port,
            pid: listener.pid,
            command: listener.command,
            user: listener.user,
            workingDirectory: listener.workingDirectory,
            applicationName: applicationName,
            displayName: listener.command,
            kind: .external,
            serverID: nil,
            isPrimaryPort: true
        )
    }

    private func systemPort(_ listener: PortInspector.Listener, applicationName: String) -> ActivePort {
        ActivePort(
            id: listener.id,
            port: listener.port,
            pid: listener.pid,
            command: listener.command,
            user: listener.user,
            workingDirectory: listener.workingDirectory,
            applicationName: applicationName,
            displayName: listener.command,
            kind: .system,
            serverID: nil,
            isPrimaryPort: true
        )
    }

    private func applicationName(for listener: PortInspector.Listener) -> String {
        let genericCommands = ["node", "bun", "bun.exe", "python", "python3", "ruby", "java", "php"]
        if genericCommands.contains(listener.command.lowercased()),
           let directory = listener.workingDirectory,
           directory != "/",
           directory != FileManager.default.homeDirectoryForCurrentUser.path {
            return URL(fileURLWithPath: directory).lastPathComponent
        }
        return listener.command
    }

    private func isPath(_ directory: String, inside root: String) -> Bool {
        let resolvedDirectory = NSString(string: directory).standardizingPath
        let resolvedRoot = NSString(string: NSString(string: root).expandingTildeInPath).standardizingPath
        return resolvedDirectory == resolvedRoot || resolvedDirectory.hasPrefix(resolvedRoot + "/")
    }

}
