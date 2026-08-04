import AppKit
import Foundation
import PortlyCore

struct ResourceHistoryPoint: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let footprintBytes: UInt64
    let residentBytes: UInt64
    let cpuPercent: Double
    let processCount: Int
}

struct ProjectResourceHistoryPoint: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let projectID: String
    let projectName: String
    let colorHex: String
    let footprintBytes: UInt64
    let residentBytes: UInt64
}

/// Owns the config and one `ServerRuntime` per configured server. Single source
/// of truth for the UI, the control API and the config file.
final class Supervisor: ObservableObject {
    static let shared = Supervisor()

    @Published private(set) var projects: [Project] = []
    @Published private(set) var resourceHistory: [ResourceHistoryPoint] = []
    @Published private(set) var projectResourceHistory: [ProjectResourceHistoryPoint] = []
    @Published private(set) var externalProcesses: [ExternalProcessSnapshot] = []
    @Published private(set) var temporaryRuntimeIDs: [String] = []
    @Published private(set) var memoryLimitRestarts: [String: MemoryLimitRestartEvent] = [:]
    /// Bumped on any runtime state change so SwiftUI redraws the lists.
    @Published private(set) var revision: Int = 0

    private let store: ConfigStore
    private(set) var runtimes: [String: ServerRuntime] = [:]
    private let metricsQueue = DispatchQueue(label: "dev.melvynx.portly.process-metrics", qos: .utility)
    private var metricsTimer: Timer?
    private var metricsSampleInFlight = false
    private var metricsSampleSequence = 0
    private var memoryLimitGuard = MemoryLimitGuard()

    private struct UpdaterRelaunchState: Codable {
        let serverIDs: [String]
    }

    private var updaterRelaunchStateURL: URL {
        PortlyPaths.configDirectory.appendingPathComponent("resume-after-update.json")
    }

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
        startMetricsTimer()
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
        let temporaryIDs = Set(temporaryRuntimeIDs)
        for (id, runtime) in runtimes where !seen.contains(id) && !temporaryIDs.contains(id) {
            runtime.stop()
            runtimes.removeValue(forKey: id)
        }
    }

    private func wire(_ runtime: ServerRuntime, temporary: Bool = false) {
        runtime.onStateChange = { [weak self, weak runtime] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.bump()
                if temporary, runtime?.isRunning == false {
                    self.scheduleTemporaryCleanup(runtimeID: runtime?.id)
                }
            }
        }
        runtime.onFailed = { runtime in
            Notifications.serverFailed(name: runtime.config.name, project: runtime.projectName, reason: runtime.lastError)
        }
    }

    private func bump() {
        revision &+= 1
    }

    private func scheduleTemporaryCleanup(runtimeID: String?) {
        guard let runtimeID, let completedAt = runtimes[runtimeID]?.temporaryFinishedAt else { return }
        // Keep completed jobs long enough for a detached agent to call
        // `portly wait <id>` and inspect logs/result after a fast command exits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3_600) { [weak self] in
            guard let self,
                  self.temporaryRuntimeIDs.contains(runtimeID),
                  let runtime = self.runtimes[runtimeID],
                  runtime.isRunning == false,
                  runtime.temporaryFinishedAt == completedAt else { return }
            self.runtimes.removeValue(forKey: runtimeID)
            self.temporaryRuntimeIDs.removeAll { $0 == runtimeID }
            self.bump()
        }
    }

    private func startMetricsTimer() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshProcessMetrics()
        }
        metricsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshProcessMetrics()
    }

    private func refreshProcessMetrics() {
        guard !metricsSampleInFlight else { return }

        let targets = runtimes.compactMapValues { runtime in
            runtime.isRunning ? runtime.pid : nil
        }
        for runtime in runtimes.values where !runtime.isRunning {
            runtime.updateProcessMetrics(nil)
        }

        metricsSampleInFlight = true
        metricsSampleSequence &+= 1
        // `ps` remains live every two seconds. More expensive cwd/listener
        // enrichment runs every ten seconds and is retained between samples.
        let includeExternalDetails = externalProcesses.isEmpty || metricsSampleSequence.isMultiple(of: 5)
        let rootProcessIDs = Set(targets.values)
        metricsQueue.async { [weak self] in
            let sample = ProcessMetricsSampler.sample(
                rootProcessIDs: rootProcessIDs,
                includeExternalDetails: includeExternalDetails
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.metricsSampleInFlight = false
                for (serverID, sampledPID) in targets {
                    guard let runtime = self.runtimes[serverID], runtime.pid == sampledPID else { continue }
                    runtime.updateProcessMetrics(sample.managedByRoot[sampledPID])
                }
                if includeExternalDetails {
                    self.externalProcesses = sample.externalProcesses
                } else {
                    let previousByPID = Dictionary(uniqueKeysWithValues: self.externalProcesses.map { ($0.pid, $0) })
                    self.externalProcesses = sample.externalProcesses.map {
                        $0.preservingDetails(from: previousByPID[$0.pid])
                    }
                }
                self.recordResourceHistory(samples: sample.managedByRoot, targets: targets)
                self.evaluateMemoryLimits(samples: sample.managedByRoot, targets: targets)
                self.bump()
            }
        }
    }

    private func recordResourceHistory(
        samples: [Int32: ProcessMetrics],
        targets: [String: Int32]
    ) {
        let now = Date()
        let point = ResourceHistoryPoint(
            timestamp: now,
            footprintBytes: samples.values.reduce(0) { $0 + $1.memoryBytes },
            residentBytes: samples.values.reduce(0) { $0 + $1.residentMemoryBytes },
            cpuPercent: samples.values.reduce(0) { $0 + $1.cpuPercent },
            processCount: samples.values.reduce(0) { $0 + $1.processCount }
        )
        resourceHistory.append(point)
        // Five minutes at the two-second sampling interval is enough to reveal
        // runaway growth without turning the monitor into another memory sink.
        if resourceHistory.count > 150 {
            resourceHistory.removeFirst(resourceHistory.count - 150)
        }

        struct ProjectTotals {
            let name: String
            let colorHex: String
            var footprintBytes: UInt64 = 0
            var residentBytes: UInt64 = 0
        }

        var projectTotals: [String: ProjectTotals] = [:]
        for (serverID, rootPID) in targets {
            guard let runtime = runtimes[serverID], let metrics = samples[rootPID] else { continue }
            let colorHex = projects.first(where: { $0.id == runtime.projectID })?.color
                ?? runtime.projectColorHex
            var total = projectTotals[runtime.projectID]
                ?? ProjectTotals(name: runtime.projectName, colorHex: colorHex)
            total.footprintBytes += metrics.memoryBytes
            total.residentBytes += metrics.residentMemoryBytes
            projectTotals[runtime.projectID] = total
        }

        projectResourceHistory.append(contentsOf: projectTotals.map { projectID, total in
            ProjectResourceHistoryPoint(
                timestamp: now,
                projectID: projectID,
                projectName: total.name,
                colorHex: total.colorHex,
                footprintBytes: total.footprintBytes,
                residentBytes: total.residentBytes
            )
        })
        let cutoff = now.addingTimeInterval(-300)
        projectResourceHistory.removeAll { $0.timestamp < cutoff }
    }

    private func evaluateMemoryLimits(
        samples: [Int32: ProcessMetrics],
        targets: [String: Int32],
        now: Date = Date()
    ) {
        let projectIDs = Set(projects.map(\.id))
        memoryLimitGuard.removeProjects(except: projectIDs)
        memoryLimitRestarts = memoryLimitRestarts.filter { projectIDs.contains($0.key) }

        for project in projects {
            let running = runtimes(inProject: project.id).filter(\.isRunning)
            let footprint = running.reduce(UInt64(0)) { total, runtime in
                guard let rootPID = targets[runtime.id], let metrics = samples[rootPID] else { return total }
                return total + metrics.memoryBytes
            }
            let limit = project.effectiveMemoryLimit(global: store.config.globalMemoryLimitBytes)
            guard memoryLimitGuard.shouldRestart(
                projectID: project.id,
                footprintBytes: footprint,
                limitBytes: limit,
                hasRunningServers: !running.isEmpty
            ), let limit else { continue }

            let serverIDs = running.map(\.id)
            memoryLimitRestarts[project.id] = MemoryLimitRestartEvent(
                projectID: project.id,
                timestamp: now,
                footprintBytes: footprint,
                limitBytes: limit,
                restartedServerIDs: serverIDs
            )
            for runtime in running {
                runtime.restartForMemoryLimit(projectFootprintBytes: footprint, limitBytes: limit)
            }
        }
    }

    func runtime(for id: String) -> ServerRuntime? { runtimes[id] }

    var temporaryRuntimes: [ServerRuntime] {
        temporaryRuntimeIDs.compactMap { runtimes[$0] }
    }

    var visibleTemporaryRuntimes: [ServerRuntime] {
        temporaryRuntimes.filter(\.isRunning)
    }

    func runtimes(inProject id: String) -> [ServerRuntime] {
        guard let project = store.config.project(id: id) else { return [] }
        return project.servers.compactMap { runtimes[$0.id] }
    }

    // MARK: - Status

    var status: PortlyStatus {
        PortlyStatus(
            version: portlyVersion,
            apiPort: store.config.apiPort,
            globalMemoryLimitBytes: store.config.globalMemoryLimitBytes,
            projects: store.config.projects.map { project in
                let memoryRestart = memoryLimitRestarts[project.id]
                return ProjectStatus(
                    id: project.id,
                    name: project.name,
                    icon: project.icon,
                    color: project.color,
                    root: project.root,
                    servers: project.servers.compactMap { runtimes[$0.id]?.status },
                    memoryLimitMode: project.memoryLimitMode,
                    memoryLimitBytes: project.memoryLimitBytes,
                    effectiveMemoryLimitBytes: project.effectiveMemoryLimit(global: store.config.globalMemoryLimitBytes),
                    lastMemoryRestartAt: memoryRestart?.timestamp,
                    lastMemoryRestartBytes: memoryRestart?.footprintBytes
                )
            },
            temporaryServers: temporaryRuntimes.map(\.status)
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

    /// Sparkle terminates the app to replace it. Remember only the servers that
    /// were active at that instant, then consume this marker on the new launch.
    /// A normal quit never writes the marker and therefore keeps its existing
    /// "quit means stop everything" behavior.
    func prepareForUpdaterRelaunch() {
        let relaunchState = UpdaterRelaunchStateStore(url: updaterRelaunchStateURL)
        let ids = runtimes.values
            .filter { $0.isRunning && !temporaryRuntimeIDs.contains($0.id) }
            .map(\.id)
            .sorted()

        guard !ids.isEmpty else {
            relaunchState.clear()
            return
        }

        do {
            PortlyPaths.ensureDirectories()
            try relaunchState.save(serverIDs: ids)
        } catch {
            NSLog("[portly] could not save update relaunch state: \(error)")
        }
    }

    func resumeAfterUpdaterRelaunchIfNeeded() {
        let relaunchState = UpdaterRelaunchStateStore(url: updaterRelaunchStateURL)
        guard let serverIDs = relaunchState.consume() else { return }
        resumeAfterUpdaterRelaunch(serverIDs: serverIDs, attemptsRemaining: 50)
    }

    private func resumeAfterUpdaterRelaunch(serverIDs: [String], attemptsRemaining: Int) {
        var waiting: [String] = []

        for id in serverIDs {
            guard let runtime = runtimes[id], !runtime.isRunning else { continue }
            if let port = runtime.config.port, PortInspector.isListening(port: port) {
                waiting.append(id)
            } else {
                runtime.start()
            }
        }

        guard !waiting.isEmpty, attemptsRemaining > 1 else {
            if !waiting.isEmpty {
                NSLog("[portly] update relaunch timed out waiting for server ports: \(waiting.joined(separator: ", "))")
            }
            return
        }

        // Sparkle can launch the replacement app while child process groups
        // from the old app are still releasing their ports. Retry for up to ten
        // seconds instead of treating that short handoff as a real conflict.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.resumeAfterUpdaterRelaunch(
                serverIDs: waiting,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
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

    func addProject(
        name: String,
        root: String,
        icon: String?,
        color: String?,
        memoryLimitMode: MemoryLimitMode = .inherit,
        memoryLimitBytes: UInt64? = nil
    ) -> Project {
        let project = Project(
            name: name,
            icon: icon ?? Project.defaultIcon,
            color: color ?? Supervisor.nextColor(excluding: store.config.projects.map(\.color)),
            root: NSString(string: root).expandingTildeInPath,
            memoryLimitMode: memoryLimitMode,
            memoryLimitBytes: memoryLimitBytes
        )
        store.mutate { $0.projects.append(project) }
        refresh()
        return project
    }

    func updateProject(_ project: Project) {
        if let previous = store.config.project(id: project.id),
           previous.memoryLimitMode != project.memoryLimitMode
            || previous.memoryLimitBytes != project.memoryLimitBytes {
            memoryLimitGuard.reset(projectID: project.id)
        }
        store.mutate { config in
            guard let idx = config.projects.firstIndex(where: { $0.id == project.id }) else { return }
            config.projects[idx] = project
        }
        refresh()
    }

    func updateGlobalMemoryLimit(_ bytes: UInt64?) {
        memoryLimitGuard.resetAll()
        store.mutate { $0.globalMemoryLimitBytes = bytes }
        refresh()
    }

    func updateProjectMemoryLimit(projectID: String, mode: MemoryLimitMode, bytes: UInt64?) {
        memoryLimitGuard.reset(projectID: projectID)
        store.mutate { config in
            guard let index = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
            config.projects[index].memoryLimitMode = mode
            config.projects[index].memoryLimitBytes = mode == .custom ? bytes : nil
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

    @discardableResult
    func runTemporary(
        name: String,
        command: String,
        directory: String,
        port: Int?,
        env: [String: String] = [:],
        healthURL: String? = nil,
        healthStatus: Int? = nil,
        timeoutSeconds: Int = TemporaryTimeout.defaultSeconds
    ) -> ServerRuntime {
        let resolvedDirectory = NSString(string: directory).expandingTildeInPath
        let resolvedName = uniqueTemporaryName(name)
        let server = ServerConfig(
            id: "tmp_" + String(UUID().uuidString.prefix(8)).lowercased(),
            name: resolvedName,
            command: command,
            port: port,
            env: env,
            healthURL: healthURL,
            healthStatus: healthStatus,
            autoRestart: false
        )
        let temporaryProject = Project(
            id: Supervisor.temporaryProjectID,
            name: "Temporary",
            icon: "clock.badge",
            color: Supervisor.temporaryProjectColor,
            root: resolvedDirectory,
            servers: [server]
        )
        let runtime = ServerRuntime(config: server, project: temporaryProject, settings: store.config)
        runtime.configureTemporaryJob(timeoutSeconds: timeoutSeconds)
        wire(runtime, temporary: true)
        runtimes[server.id] = runtime
        temporaryRuntimeIDs.append(server.id)
        bump()
        runtime.start()
        return runtime
    }

    private func uniqueTemporaryName(_ requestedName: String) -> String {
        let base = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Temporary process"
            : requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Set(temporaryRuntimes.map { $0.config.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
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
        if temporaryRuntimeIDs.contains(id) {
            guard let runtime = runtime(for: id) else { return }
            if runtime.isRunning {
                runtime.stop { [weak self] in
                    self?.removeTemporaryRuntime(id: id)
                }
            } else {
                removeTemporaryRuntime(id: id)
            }
            return
        }
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

    private func removeTemporaryRuntime(id: String) {
        runtimes.removeValue(forKey: id)
        temporaryRuntimeIDs.removeAll { $0 == id }
        bump()
    }

    func refresh() {
        projects = store.config.projects
        syncRuntimes()
        bump()
    }

    func updateRuntimeSettings(
        healthIntervalSeconds: Int,
        maxRestartAttempts: Int,
        logBufferLines: Int,
        logFileMaxMB: Int
    ) {
        store.mutate { config in
            config.healthIntervalSeconds = healthIntervalSeconds
            config.maxRestartAttempts = maxRestartAttempts
            config.logBufferLines = logBufferLines
            config.logFileMaxMB = logFileMaxMB
        }
        refresh()
    }

    // MARK: - Resolution helpers (shared by the API and the UI)

    func resolveServer(_ query: String) -> ServerRuntime? {
        if let hit = store.config.resolveServer(query) { return runtimes[hit.server.id] }
        if let runtime = temporaryRuntimes.first(where: { $0.id == query }) { return runtime }
        let normalized = query.split(separator: "/", maxSplits: 1).last.map(String.init) ?? query
        return temporaryRuntimes.first {
            $0.config.name.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    func resolveProject(_ query: String) -> Project? {
        store.config.resolveProject(query)
    }

    func project(containing serverID: String) -> Project? {
        store.config.projects.first { $0.servers.contains { $0.id == serverID } }
    }

    func server(configuredOn port: Int, excluding serverID: String? = nil) -> (project: Project, server: ServerConfig)? {
        for project in store.config.projects {
            if let server = project.servers.first(where: { $0.port == port && $0.id != serverID }) {
                return (project, server)
            }
        }
        if let runtime = temporaryRuntimes.first(where: {
            $0.id != serverID && $0.config.port == port
        }) {
            return (
                Project(
                    id: Supervisor.temporaryProjectID,
                    name: "Temporary",
                    icon: "clock.badge",
                    color: Supervisor.temporaryProjectColor,
                    root: runtime.workingDirectory,
                    servers: [runtime.config]
                ),
                runtime.config
            )
        }
        return nil
    }

    func nextAvailablePort(startingAt start: Int = 3000, excluding serverID: String? = nil) -> Int {
        for port in max(1, start)...65_535 {
            if server(configuredOn: port, excluding: serverID) == nil, PortInspector.occupant(of: port) == nil {
                return port
            }
        }
        return start
    }

    // MARK: - Ports

    func occupant(of port: Int) -> PortOccupant? {
        guard let found = PortInspector.occupant(of: port) else { return nil }
        let owned = runtimes.values.first { $0.status.pid == found.pid || ($0.config.port == port && $0.isRunning) }
        let container = DockerPortInspector.container(publishing: port)
        return PortOccupant(
            port: port,
            pid: found.pid,
            command: found.command,
            user: found.user,
            ownedByPortly: owned != nil,
            serverID: owned?.id,
            dockerContainerID: container?.id,
            dockerContainerName: container?.name,
            dockerComposeProject: container?.composeProject,
            dockerComposeService: container?.composeService
        )
    }

    /// The palette is intentionally the macOS system colors, so projects read as
    /// native rather than branded. The order matters: colors are handed out in this
    /// sequence, and every adjacent pair sits at least 86 degrees apart in OKLCH hue,
    /// so the first projects you create never look alike in the charts.
    static let palette = [
        "#0A84FF", // Blue
        "#FF9F0A", // Orange
        "#BF5AF2", // Purple
        "#30D158", // Green
        "#FF375F", // Pink
        "#64D2FF", // Cyan
        "#FFD60A", // Yellow
        "#5E5CE6", // Indigo
        "#66D4CF", // Mint
        "#8E8E93", // Gray
    ]
    static let paletteNames = [
        "Blue", "Orange", "Purple", "Green", "Pink", "Cyan", "Yellow", "Indigo", "Mint", "Gray",
    ]
    static let temporaryProjectID = "portly-temporary"
    static let temporaryProjectColor = "#8E8E93"

    /// Hands out the first palette color no project uses yet, so two projects never
    /// end up with the same line in the resource charts. Once every color is taken,
    /// the least used one wins.
    static func nextColor(excluding used: [String]) -> String {
        var counts: [String: Int] = [:]
        for hex in used {
            counts[hex.uppercased(), default: 0] += 1
        }
        var best = palette[0]
        var bestCount = Int.max
        for hex in palette {
            let count = counts[hex.uppercased()] ?? 0
            guard count < bestCount else { continue }
            best = hex
            bestCount = count
            if count == 0 { break }
        }
        return best
    }
}
