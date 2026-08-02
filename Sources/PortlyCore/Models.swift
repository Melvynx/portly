import Foundation

// MARK: - Config model (what lives in ~/.config/portly/config.json)

public struct ServerConfig: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Shell command, run through `zsh -lc` so PATH / nvm / mise are inherited.
    public var command: String
    /// Port the server is expected to listen on. Drives the TCP health check.
    public var port: Int?
    /// Working directory. Relative paths resolve against the project root.
    public var directory: String?
    public var env: [String: String]
    /// Optional HTTP health check. Either a path ("/api/health") resolved against
    /// http://127.0.0.1:<port>, or a full URL.
    public var healthURL: String?
    /// Expected HTTP status for the health URL. Any 2xx/3xx if nil.
    public var healthStatus: Int?
    /// When false, a crash leaves the server stopped instead of restarting it.
    public var autoRestart: Bool

    public init(
        id: String = ServerConfig.newID(),
        name: String,
        command: String,
        port: Int? = nil,
        directory: String? = nil,
        env: [String: String] = [:],
        healthURL: String? = nil,
        healthStatus: Int? = nil,
        autoRestart: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.port = port
        self.directory = directory
        self.env = env
        self.healthURL = healthURL
        self.healthStatus = healthStatus
        self.autoRestart = autoRestart
    }

    public static func newID() -> String { "srv_" + String(UUID().uuidString.prefix(8)).lowercased() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ServerConfig.newID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        healthURL = try c.decodeIfPresent(String.self, forKey: .healthURL)
        healthStatus = try c.decodeIfPresent(Int.self, forKey: .healthStatus)
        autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? true
    }
}

public struct Project: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// SF Symbol name drawn in the project's color. Not an emoji: a tinted
    /// symbol matches the rest of the system UI at every size.
    public var icon: String
    /// Hex color used for the icon and the accent dot.
    public var color: String
    /// Absolute path to the project root.
    public var root: String
    public var servers: [ServerConfig]

    public init(
        id: String = Project.newID(),
        name: String,
        icon: String = Project.defaultIcon,
        color: String = "#8E8E93",
        root: String,
        servers: [ServerConfig] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.root = root
        self.servers = servers
    }

    public static func newID() -> String { "prj_" + String(UUID().uuidString.prefix(8)).lowercased() }

    public static let defaultIcon = "shippingbox.fill"

    /// The icons offered in the UI and accepted by the CLI. Short on purpose:
    /// enough to tell projects apart at a glance, not a symbol browser.
    public static let icons = [
        "shippingbox.fill", "cube.fill", "globe", "server.rack", "bolt.fill",
        "cloud.fill", "hammer.fill", "flask.fill", "cart.fill", "envelope.fill",
        "chart.bar.fill", "star.fill", "heart.fill", "gamecontroller.fill",
        "camera.fill", "music.note", "book.fill", "terminal.fill",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Project.newID()
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? Project.defaultIcon
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#8E8E93"
        root = try c.decode(String.self, forKey: .root)
        servers = try c.decodeIfPresent([ServerConfig].self, forKey: .servers) ?? []
    }
}

public struct PortlyConfig: Codable {
    public var version: Int
    /// Port of the local HTTP control API the CLI and agents talk to.
    public var apiPort: Int
    /// Seconds between health checks.
    public var healthIntervalSeconds: Int
    /// Consecutive failed restarts before a server is parked in `.failed`.
    public var maxRestartAttempts: Int
    /// Lines of scrollback kept in memory per server.
    public var logBufferLines: Int
    /// Per-server log file cap before rotation, in megabytes.
    public var logFileMaxMB: Int
    public var projects: [Project]

    public static let defaultAPIPort = 7737

    public init(
        version: Int = 1,
        apiPort: Int = PortlyConfig.defaultAPIPort,
        healthIntervalSeconds: Int = 10,
        maxRestartAttempts: Int = 5,
        logBufferLines: Int = 5000,
        logFileMaxMB: Int = 10,
        projects: [Project] = []
    ) {
        self.version = version
        self.apiPort = apiPort
        self.healthIntervalSeconds = healthIntervalSeconds
        self.maxRestartAttempts = maxRestartAttempts
        self.logBufferLines = logBufferLines
        self.logFileMaxMB = logFileMaxMB
        self.projects = projects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        apiPort = try c.decodeIfPresent(Int.self, forKey: .apiPort) ?? PortlyConfig.defaultAPIPort
        healthIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .healthIntervalSeconds) ?? 10
        maxRestartAttempts = try c.decodeIfPresent(Int.self, forKey: .maxRestartAttempts) ?? 5
        logBufferLines = try c.decodeIfPresent(Int.self, forKey: .logBufferLines) ?? 5000
        logFileMaxMB = try c.decodeIfPresent(Int.self, forKey: .logFileMaxMB) ?? 10
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
    }

    public func project(id: String) -> Project? { projects.first { $0.id == id } }

    public func server(id: String) -> (project: Project, server: ServerConfig)? {
        for p in projects {
            if let s = p.servers.first(where: { $0.id == id }) { return (p, s) }
        }
        return nil
    }

    /// Resolves a user-supplied identifier to a server: exact id, or a
    /// case-insensitive name match, optionally qualified as "project/server".
    public func resolveServer(_ query: String) -> (project: Project, server: ServerConfig)? {
        if let hit = server(id: query) { return hit }
        let parts = query.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard let p = resolveProject(parts[0]) else { return nil }
            if let s = p.servers.first(where: { $0.name.caseInsensitiveCompare(parts[1]) == .orderedSame }) {
                return (p, s)
            }
            return nil
        }
        for p in projects {
            if let s = p.servers.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
                return (p, s)
            }
        }
        return nil
    }

    public func resolveProject(_ query: String) -> Project? {
        if let p = project(id: query) { return p }
        return projects.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    }
}

// MARK: - Runtime state

public enum ServerState: String, Codable, Hashable {
    case stopped
    case starting
    case running
    case unhealthy
    case restarting
    case failed
}

public struct ServerStatus: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var projectID: String
    public var projectName: String
    public var command: String
    public var port: Int?
    public var directory: String
    public var state: ServerState
    public var pid: Int32?
    public var startedAt: Date?
    public var restartCount: Int
    public var lastExitCode: Int32?
    public var lastError: String?
    public var healthy: Bool
    public var url: String?
    public var cpuPercent: Double?
    /// Total physical footprint, including compressed and swapped owned pages.
    public var memoryBytes: UInt64?
    /// Portion of the process tree currently resident in RAM.
    public var residentMemoryBytes: UInt64?
    public var processCount: Int?

    public init(
        id: String, name: String, projectID: String, projectName: String,
        command: String, port: Int?, directory: String, state: ServerState,
        pid: Int32?, startedAt: Date?, restartCount: Int, lastExitCode: Int32?,
        lastError: String?, healthy: Bool, url: String?,
        cpuPercent: Double? = nil, memoryBytes: UInt64? = nil,
        residentMemoryBytes: UInt64? = nil, processCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.projectName = projectName
        self.command = command
        self.port = port
        self.directory = directory
        self.state = state
        self.pid = pid
        self.startedAt = startedAt
        self.restartCount = restartCount
        self.lastExitCode = lastExitCode
        self.lastError = lastError
        self.healthy = healthy
        self.url = url
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.residentMemoryBytes = residentMemoryBytes
        self.processCount = processCount
    }
}

public struct ProjectStatus: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var icon: String
    public var color: String
    public var root: String
    public var servers: [ServerStatus]

    public init(id: String, name: String, icon: String, color: String, root: String, servers: [ServerStatus]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.root = root
        self.servers = servers
    }
}

public struct PortlyStatus: Codable {
    public var version: String
    public var apiPort: Int
    public var projects: [ProjectStatus]

    public init(version: String, apiPort: Int, projects: [ProjectStatus]) {
        self.version = version
        self.apiPort = apiPort
        self.projects = projects
    }
}

public struct PortOccupant: Codable, Hashable {
    public var port: Int
    public var pid: Int32
    public var command: String
    public var user: String
    /// True when the listener is one of Portly's own supervised servers.
    public var ownedByPortly: Bool
    public var serverID: String?

    public init(port: Int, pid: Int32, command: String, user: String, ownedByPortly: Bool, serverID: String?) {
        self.port = port
        self.pid = pid
        self.command = command
        self.user = user
        self.ownedByPortly = ownedByPortly
        self.serverID = serverID
    }
}
