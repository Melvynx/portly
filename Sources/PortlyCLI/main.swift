import ArgumentParser
import Darwin
import Foundation
import PortlyCore

// MARK: - Shared helpers

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print raw JSON instead of a human summary.")
    var json = false

    @Option(name: .long, help: "Override the control API port.")
    var apiPort: Int?
}

func client(_ options: GlobalOptions) -> PortlyClient {
    PortlyClient(port: options.apiPort)
}

func emit<T: Codable>(_ value: T, json: Bool, human: (T) -> String) {
    if json {
        let data = (try? PortlyAPI.encoder().encode(value)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(human(value))
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
    exit(1)
}

extension ServerStatus {
    var stateGlyph: String {
        switch state {
        case .running: return "●"
        case .starting, .restarting: return "◐"
        case .unhealthy: return "◍"
        case .failed: return "✕"
        case .stopped: return "○"
        }
    }

    var line: String {
        let port = self.port.map { ":\($0)" } ?? ""
        let uptime = startedAt.map { " up \(Int(Date().timeIntervalSince($0)))s" } ?? ""
        let restarts = restartCount > 0 ? " restarts:\(restartCount)" : ""
        return "  \(stateGlyph) \(name)\(port)  \(state.rawValue)\(uptime)\(restarts)"
    }
}

func render(_ status: PortlyStatus) -> String {
    guard !status.projects.isEmpty else {
        return "No projects yet. Add one with: portly add-project --name <name> --path <folder>"
    }
    var out: [String] = []
    for project in status.projects {
        out.append("\(project.name)  (\(project.id))")
        if project.servers.isEmpty {
            out.append("  no servers")
        } else {
            out.append(contentsOf: project.servers.map(\.line))
        }
        out.append("")
    }
    return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
}

// MARK: - Root

struct Portly: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "portly",
        abstract: "Control Portly, the macOS dev server manager.",
        discussion: """
        Portly keeps local dev servers running on fixed ports, restarts them when \
        they crash, and exposes everything through this CLI so an agent can drive it.

        Every command starts Portly.app if it is not already running.
        """,
        version: portlyVersion,
        subcommands: [
            Status.self, Start.self, Stop.self, Restart.self, Logs.self,
            AddProject.self, AddServer.self, UpdateServer.self,
            Remove.self, TakeOver.self, Port.self, KillPort.self, Open.self, Quit.self, Forever.self, Config.self,
        ],
        defaultSubcommand: Status.self
    )
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "List every project and server with its live state.",
        aliases: ["list", "ls"]
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        do {
            let status = try client(options).get("status", as: PortlyStatus.self)
            emit(status, json: options.json, human: render)
        } catch {
            fail(error.localizedDescription)
        }
    }
}

// MARK: - Lifecycle

struct TargetOptions: ParsableArguments {
    @Argument(help: "Server name or id. Use \"project/server\" to disambiguate.")
    var server: String?

    @Option(name: .long, help: "Act on every server in this project instead.")
    var project: String?
}

private func runAction(_ path: String, _ target: TargetOptions, _ options: GlobalOptions) {
    let body = PortlyAPI.TargetRequest(server: target.server, project: target.project)
    do {
        let response = try client(options).post(path, body, as: PortlyAPI.ActionResponse.self)
        emit(response, json: options.json) { $0.message }
    } catch {
        fail(error.localizedDescription)
    }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a server, or a whole project.")
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: GlobalOptions

    func run() throws {
        guard target.server != nil || target.project != nil else {
            fail("Pass a server name, or --project <name>.")
        }
        runAction("start", target, options)
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop a server, a project, or everything.")
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Stop every server Portly manages.")
    var all = false

    func run() throws {
        guard all || target.server != nil || target.project != nil else {
            fail("Pass a server name, --project <name>, or --all.")
        }
        runAction("stop", target, options)
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart a server or a project.")
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: GlobalOptions

    func run() throws {
        guard target.server != nil || target.project != nil else {
            fail("Pass a server name, or --project <name>.")
        }
        runAction("restart", target, options)
    }
}

// MARK: - Logs

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the recent output of a server.")

    @Argument(help: "Server name or id.")
    var server: String

    @Option(name: .shortAndLong, help: "Number of lines to show.")
    var tail: Int = 200

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let escaped = server.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? server
        do {
            let response = try client(options).get("logs?server=\(escaped)&tail=\(tail)", as: PortlyAPI.LogsResponse.self)
            emit(response, json: options.json) { $0.lines.joined(separator: "\n") }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

// MARK: - Config mutations

struct AddProject: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-project",
        abstract: "Register a project folder."
    )

    @Option(name: .long, help: "Project name.")
    var name: String

    @Option(name: .long, help: "Absolute path to the project folder.")
    var path: String

    @Option(name: .long, help: "SF Symbol name shown in the sidebar, for example globe.")
    var icon: String?

    @Option(name: .long, help: "Hex color for the project icon.")
    var color: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let body = PortlyAPI.AddProjectRequest(name: name, root: path, icon: icon, color: color)
        do {
            let project = try client(options).post("projects/add", body, as: Project.self)
            emit(project, json: options.json) { "Added project \($0.name) (\($0.id))" }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

struct AddServer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-server",
        abstract: "Add a server to a project."
    )

    @Option(name: .long, help: "Project name or id.")
    var project: String

    @Option(name: .long, help: "Server name, for example \"web\".")
    var name: String

    @Option(name: .long, help: "Command to run, executed through a login shell.")
    var command: String

    @Option(name: .long, help: "Port the server listens on.")
    var port: Int?

    @Option(name: .long, help: "Working directory, relative to the project folder or absolute.")
    var directory: String?

    @Option(name: .long, help: "Health check path or URL, for example /api/health.")
    var healthUrl: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Environment variables as KEY=VALUE.")
    var env: [String] = []

    @Flag(name: .long, inversion: .prefixedNo, help: "Restart automatically after a crash.")
    var autoRestart = true

    @Flag(name: .long, help: "Start the server right after adding it.")
    var start = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var parsedEnv: [String: String] = [:]
        for entry in env {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { fail("Bad --env value '\(entry)', expected KEY=VALUE") }
            parsedEnv[String(parts[0])] = String(parts[1])
        }
        let body = PortlyAPI.AddServerRequest(
            project: project, name: name, command: command, port: port,
            directory: directory, env: parsedEnv.isEmpty ? nil : parsedEnv,
            healthURL: healthUrl, healthStatus: nil,
            autoRestart: autoRestart, start: start
        )
        do {
            let server = try client(options).post("servers/add", body, as: ServerConfig.self)
            emit(server, json: options.json) { "Added server \($0.name) (\($0.id))" }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

struct UpdateServer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-server",
        abstract: "Change an existing server's settings."
    )

    @Argument(help: "Server name or id.")
    var server: String

    @Option(name: .long) var name: String?
    @Option(name: .long) var command: String?
    @Option(name: .long) var port: Int?
    @Option(name: .long) var directory: String?
    @Option(name: .long) var healthUrl: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Restart automatically after a crash.")
    var autoRestart: Bool?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var body = PortlyAPI.UpdateServerRequest(server: server)
        body.name = name
        body.command = command
        body.port = port
        body.directory = directory
        body.healthURL = healthUrl
        body.autoRestart = autoRestart
        do {
            let updated = try client(options).post("servers/update", body, as: ServerConfig.self)
            emit(updated, json: options.json) { "Updated \($0.name)" }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a server or a project.")

    @Argument(help: "Server name or id.")
    var server: String?

    @Option(name: .long, help: "Remove a whole project instead.")
    var project: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        do {
            if let project {
                let body = PortlyAPI.RemoveRequest(project: project)
                let response = try client(options).post("projects/remove", body, as: PortlyAPI.ActionResponse.self)
                emit(response, json: options.json) { $0.message }
            } else if let server {
                let body = PortlyAPI.RemoveRequest(server: server)
                let response = try client(options).post("servers/remove", body, as: PortlyAPI.ActionResponse.self)
                emit(response, json: options.json) { $0.message }
            } else {
                fail("Pass a server name, or --project <name>.")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

struct TakeOver: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "take-over",
        abstract: "Stop an external listener and relaunch the configured server under Portly.",
        aliases: ["adopt"]
    )

    @Argument(help: "Server name or id. Use project/server to disambiguate.")
    var server: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        do {
            let body = PortlyAPI.TakeOverRequest(server: server)
            let response = try client(options).post("servers/take-over", body, as: PortlyAPI.ActionResponse.self)
            emit(response, json: options.json) { $0.message }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

// MARK: - Ports

struct Port: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what is listening on a port.")

    @Argument(help: "Port number.")
    var port: Int

    @OptionGroup var options: GlobalOptions

    func run() throws {
        do {
            let response = try client(options).get("ports?port=\(port)", as: PortlyAPI.PortQueryResponse.self)
            emit(response, json: options.json) { result in
                guard let occupant = result.occupant else { return "Port \(result.port) is free." }
                let owner = occupant.ownedByPortly ? " (managed by Portly)" : ""
                return "Port \(result.port): \(occupant.command) pid \(occupant.pid)\(owner)"
            }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

struct KillPort: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill-port",
        abstract: "Send SIGTERM to whatever holds a port."
    )

    @Argument(help: "Port number.")
    var port: Int

    @OptionGroup var options: GlobalOptions

    func run() throws {
        do {
            let response = try client(options).post("ports/kill", PortlyAPI.KillPortRequest(port: port), as: PortlyAPI.ActionResponse.self)
            emit(response, json: options.json) { $0.message }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

// MARK: - App control

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bring the Portly window to the front.")
    @OptionGroup var options: GlobalOptions

    func run() throws {
        do {
            let response = try client(options).post("open", PortlyAPI.Empty(), as: PortlyAPI.ActionResponse.self)
            emit(response, json: options.json) { $0.message }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

struct Quit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quit Portly, stopping every server.")
    @OptionGroup var options: GlobalOptions

    func run() throws {
        do {
            let response = try client(options).request(
                "POST", "quit", body: PortlyAPI.Empty(), as: PortlyAPI.ActionResponse.self, autoLaunch: false
            )
            emit(response, json: options.json) { $0.message }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

// MARK: - macOS persistence

private struct ForeverState: Codable {
    let enabled: Bool
    let loaded: Bool
    let label: String
    let plist: String
    let appExecutable: String
}

private enum ForeverManager {
    static let label = "dev.portly.forever"

    static var domain: String { "gui/\(getuid())" }
    static var service: String { "\(domain)/\(label)" }
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static let appExecutable = "/Applications/Portly.app/Contents/MacOS/Portly"

    static func state() -> ForeverState {
        ForeverState(
            enabled: FileManager.default.fileExists(atPath: plistURL.path),
            loaded: launchctl(["print", service]).status == 0,
            label: label,
            plist: plistURL.path,
            appExecutable: appExecutable
        )
    }

    static func enable(options: GlobalOptions) throws -> ForeverState {
        guard FileManager.default.isExecutableFile(atPath: appExecutable) else {
            throw ValidationError("Install /Applications/Portly.app first with ./build.sh --run.")
        }

        let activeServers = try stopCurrentApp(options: options)
        _ = launchctl(["bootout", service])

        let fm = FileManager.default
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: PortlyPaths.logsDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [appExecutable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": PortlyPaths.logsDirectory.appendingPathComponent("portly-launchd.log").path,
            "StandardErrorPath": PortlyPaths.logsDirectory.appendingPathComponent("portly-launchd-error.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        let bootstrap = launchctl(["bootstrap", domain, plistURL.path])
        guard bootstrap.status == 0 else {
            throw ValidationError("launchctl bootstrap failed: \(bootstrap.output)")
        }
        guard waitForAPI(options: options) else {
            throw ValidationError("launchd loaded Portly, but its control API did not become reachable.")
        }
        try restore(activeServers, options: options)
        return state()
    }

    static func disable(options: GlobalOptions) throws -> ForeverState {
        let activeServers = try stopCurrentApp(options: options)
        _ = launchctl(["bootout", service])
        try movePlistToTrashIfPresent()

        if !activeServers.isEmpty {
            let c = client(options)
            guard c.launchAppIfNeeded(), waitForAPI(options: options) else {
                throw ValidationError("Launch at login was disabled, but Portly could not be relaunched.")
            }
            try restore(activeServers, options: options)
        }
        return state()
    }

    private static func stopCurrentApp(options: GlobalOptions) throws -> [String] {
        let c = client(options)
        var active: [String] = []

        if c.isReachable() {
            let status = try c.get("status", as: PortlyStatus.self)
            active = status.projects.flatMap(\.servers).filter {
                $0.state != .stopped && $0.state != .failed
            }.map(\.id)

            _ = try c.request(
                "POST", "quit", body: PortlyAPI.Empty(),
                as: PortlyAPI.ActionResponse.self, autoLaunch: false
            )
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, c.isReachable(timeout: 0.3) {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // LaunchServices can retain a development bundle with the same bundle ID.
        // Ensure no dist/debug copy can race the launchd-owned installed app for 7737.
        terminateOtherAppInstances()
        return active
    }

    private static func terminateOtherAppInstances() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = [
            "-U", String(getuid()), "-f",
            #"/Portly\.app/Contents/MacOS/Portly$"#,
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pids = output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        guard !pids.isEmpty else { return }

        pids.forEach { _ = kill($0, SIGTERM) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        pids.filter { kill($0, 0) == 0 }.forEach { _ = kill($0, SIGKILL) }
    }

    private static func waitForAPI(options: GlobalOptions) -> Bool {
        let c = client(options)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if c.isReachable(timeout: 0.5) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private static func restore(_ serverIDs: [String], options: GlobalOptions) throws {
        let c = client(options)
        for id in serverIDs {
            let body = PortlyAPI.TargetRequest(server: id)
            _ = try c.post("start", body, as: PortlyAPI.ActionResponse.self)
        }
    }

    private static func movePlistToTrashIfPresent() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plistURL.path) else { return }
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = trash.appendingPathComponent("\(label)-\(stamp).plist")
        try fm.moveItem(at: plistURL, to: destination)
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct Forever: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep Portly available across macOS logins.",
        subcommands: [Enable.self, Disable.self, ForeverStatus.self],
        defaultSubcommand: ForeverStatus.self
    )

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install and load the Portly LaunchAgent.")
        @OptionGroup var options: GlobalOptions

        func run() throws {
            let state = try ForeverManager.enable(options: options)
            emit(state, json: options.json) { _ in
                "Portly will launch at login and is now supervised by launchd."
            }
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unload the Portly LaunchAgent.")
        @OptionGroup var options: GlobalOptions

        func run() throws {
            let state = try ForeverManager.disable(options: options)
            emit(state, json: options.json) { _ in "Portly launch at login is disabled." }
        }
    }

    struct ForeverStatus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show LaunchAgent installation and live state."
        )
        @OptionGroup var options: GlobalOptions

        func run() throws {
            let state = ForeverManager.state()
            emit(state, json: options.json) {
                "Launch at login: \($0.enabled ? "enabled" : "disabled") (launchd \($0.loaded ? "loaded" : "not loaded"))"
            }
        }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the config file path and contents.")

    @Flag(name: .long, help: "Print only the path.")
    var pathOnly = false

    func run() throws {
        let url = PortlyPaths.configFile
        if pathOnly {
            print(url.path)
            return
        }
        print("# \(url.path)")
        if let data = try? Data(contentsOf: url) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("(not created yet, launch Portly once)")
        }
    }
}

Portly.main()
