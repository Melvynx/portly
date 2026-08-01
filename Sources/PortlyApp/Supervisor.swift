import AppKit
import Foundation
import PortlyCore

/// Owns the config and one `ServerRuntime` per configured server. Single source
/// of truth for the UI, the control API and the config file.
final class Supervisor: ObservableObject {
    static let shared = Supervisor()

    @Published private(set) var projects: [Project] = []
    /// Bumped on any runtime state change so SwiftUI redraws the lists.
    @Published private(set) var revision: Int = 0

    private let store: ConfigStore
    private(set) var runtimes: [String: ServerRuntime] = [:]

    var settings: PortlyConfig { store.config }

    private init() {
        store = ConfigStore()
        projects = store.config.projects
        syncRuntimes()
        store.onExternalChange = { [weak self] config in
            guard let self else { return }
            self.projects = config.projects
            self.syncRuntimes()
            self.bump()
        }
        store.startWatching()
    }

    // MARK: - Runtime bookkeeping

    private func syncRuntimes() {
        var seen = Set<String>()
        for project in store.config.projects {
            for server in project.servers {
                seen.insert(server.id)
                if let existing = runtimes[server.id] {
                    existing.apply(config: server, project: project, settings: store.config)
                } else {
                    let runtime = ServerRuntime(config: server, project: project, settings: store.config)
                    wire(runtime)
                    runtimes[server.id] = runtime
                }
            }
        }
        // A server removed from the config must not keep running.
        for (id, runtime) in runtimes where !seen.contains(id) {
            runtime.stop()
            runtimes.removeValue(forKey: id)
        }
    }

    private func wire(_ runtime: ServerRuntime) {
        runtime.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.bump() }
        }
        runtime.onFailed = { runtime in
            Notifications.serverFailed(name: runtime.config.name, project: runtime.projectName, reason: runtime.lastError)
        }
    }

    private func bump() {
        revision &+= 1
    }

    func runtime(for id: String) -> ServerRuntime? { runtimes[id] }

    func runtimes(inProject id: String) -> [ServerRuntime] {
        guard let project = store.config.project(id: id) else { return [] }
        return project.servers.compactMap { runtimes[$0.id] }
    }

    // MARK: - Status

    var status: PortlyStatus {
        PortlyStatus(
            version: portlyVersion,
            apiPort: store.config.apiPort,
            projects: store.config.projects.map { project in
                ProjectStatus(
                    id: project.id,
                    name: project.name,
                    icon: project.icon,
                    color: project.color,
                    root: project.root,
                    servers: project.servers.compactMap { runtimes[$0.id]?.status }
                )
            }
        )
    }

    var runningCount: Int {
        runtimes.values.filter { $0.isRunning }.count
    }

    var hasProblem: Bool {
        runtimes.values.contains { $0.state == .failed || $0.state == .unhealthy }
    }

    // MARK: - Actions

    func start(serverID: String) { runtime(for: serverID)?.start() }
    func stop(serverID: String) { runtime(for: serverID)?.stop() }
    func restart(serverID: String) { runtime(for: serverID)?.restart() }

    func startProject(_ id: String) {
        runtimes(inProject: id).forEach { $0.start() }
    }

    func stopProject(_ id: String) {
        runtimes(inProject: id).forEach { $0.stop() }
    }

    func stopAll() {
        runtimes.values.forEach { $0.stop() }
    }

    /// Blocks briefly on quit so children get a chance to die with us.
    func terminateEverythingSynchronously() {
        let running = runtimes.values.filter { $0.isRunning }
        guard !running.isEmpty else { return }
        running.forEach { $0.stop() }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, runtimes.values.contains(where: { $0.isRunning }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        // Anything still alive gets a hard kill so no port stays held.
        for runtime in runtimes.values {
            if let pid = runtime.status.pid, pid > 0 {
                kill(-pid, SIGKILL)
            }
        }
    }

    // MARK: - Config mutations

    func addProject(name: String, root: String, icon: String?, color: String?) -> Project {
        let project = Project(
            name: name,
            icon: icon ?? Project.defaultIcon,
            color: color ?? Supervisor.nextColor(index: store.config.projects.count),
            root: NSString(string: root).expandingTildeInPath
        )
        store.mutate { $0.projects.append(project) }
        refresh()
        return project
    }

    func updateProject(_ project: Project) {
        store.mutate { config in
            guard let idx = config.projects.firstIndex(where: { $0.id == project.id }) else { return }
            config.projects[idx] = project
        }
        refresh()
    }

    func removeProject(id: String) {
        runtimes(inProject: id).forEach { $0.stop() }
        store.mutate { config in
            config.projects.removeAll { $0.id == id }
        }
        refresh()
    }

    @discardableResult
    func addServer(projectID: String, server: ServerConfig) -> ServerConfig? {
        var added: ServerConfig?
        store.mutate { config in
            guard let idx = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
            config.projects[idx].servers.append(server)
            added = server
        }
        refresh()
        return added
    }

    func updateServer(_ server: ServerConfig) {
        store.mutate { config in
            for (pIdx, project) in config.projects.enumerated() {
                if let sIdx = project.servers.firstIndex(where: { $0.id == server.id }) {
                    config.projects[pIdx].servers[sIdx] = server
                    return
                }
            }
        }
        refresh()
    }

    func removeServer(id: String) {
        runtime(for: id)?.stop()
        store.mutate { config in
            for (pIdx, project) in config.projects.enumerated() {
                if project.servers.contains(where: { $0.id == id }) {
                    config.projects[pIdx].servers.removeAll { $0.id == id }
                    return
                }
            }
        }
        refresh()
    }

    func refresh() {
        projects = store.config.projects
        syncRuntimes()
        bump()
    }

    // MARK: - Resolution helpers (shared by the API and the UI)

    func resolveServer(_ query: String) -> ServerRuntime? {
        guard let hit = store.config.resolveServer(query) else { return nil }
        return runtimes[hit.server.id]
    }

    func resolveProject(_ query: String) -> Project? {
        store.config.resolveProject(query)
    }

    func project(containing serverID: String) -> Project? {
        store.config.projects.first { $0.servers.contains { $0.id == serverID } }
    }

    // MARK: - Ports

    func occupant(of port: Int) -> PortOccupant? {
        guard let found = PortInspector.occupant(of: port) else { return nil }
        let owned = runtimes.values.first { $0.status.pid == found.pid || ($0.config.port == port && $0.isRunning) }
        return PortOccupant(
            port: port,
            pid: found.pid,
            command: found.command,
            user: found.user,
            ownedByPortly: owned != nil,
            serverID: owned?.id
        )
    }

    /// The palette is intentionally the macOS system colors, so projects read as
    /// native rather than branded.
    static let palette = ["#0A84FF", "#30D158", "#FF9F0A", "#FF375F", "#BF5AF2", "#64D2FF", "#FFD60A", "#8E8E93"]

    static func nextColor(index: Int) -> String {
        palette[index % palette.count]
    }
}
