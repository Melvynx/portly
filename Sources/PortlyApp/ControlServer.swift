import AppKit
import Foundation
import Network
import PortlyCore

/// Tiny HTTP/1.1 server bound to 127.0.0.1 only. This is the surface an agent
/// drives through the `portly` CLI.
final class ControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.portly.api")
    private let supervisor: Supervisor
    private(set) var port: Int

    init(supervisor: Supervisor, port: Int) {
        self.supervisor = supervisor
        self.port = port
    }

    func start() {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: this API can start processes, it must never be remote.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("[portly] control API failed: \(error)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("[portly] could not bind control API on \(port): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(buffer) {
                self.respond(to: request, on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        DispatchQueue.main.async {
            let (status, body) = self.route(request)
            var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            var payload = Data(head.utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) -> (Int, Data) {
        do {
            switch (request.method, request.path) {
            case ("GET", "/ping"):
                return (200, try ok(["pong": portlyVersion]))

            case ("GET", "/status"):
                return (200, try ok(supervisor.status))

            case ("GET", "/config"):
                return (200, try ok(supervisor.settings))

            case ("POST", "/start"), ("POST", "/stop"), ("POST", "/restart"):
                let body: PortlyAPI.TargetRequest = try request.decode()
                return (200, try ok(try act(request.path, body)))

            case ("GET", "/logs"):
                let query = request.query["server"] ?? ""
                let tail = Int(request.query["tail"] ?? "200") ?? 200
                guard let runtime = supervisor.resolveServer(query) else {
                    return (404, try fail("No server matching '\(query)'"))
                }
                return (200, try ok(PortlyAPI.LogsResponse(server: runtime.config.name, lines: runtime.logTail(tail))))

            case ("POST", "/projects/add"):
                let body: PortlyAPI.AddProjectRequest = try request.decode()
                let root = NSString(string: body.root).expandingTildeInPath
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                    return (400, try fail("Directory does not exist: \(root)"))
                }
                if supervisor.resolveProject(body.name) != nil {
                    return (400, try fail("A project named '\(body.name)' already exists"))
                }
                let project = supervisor.addProject(name: body.name, root: root, icon: body.icon, color: body.color)
                return (200, try ok(project))

            case ("POST", "/projects/remove"):
                let body: PortlyAPI.RemoveRequest = try request.decode()
                guard let query = body.project, let project = supervisor.resolveProject(query) else {
                    return (404, try fail("No project matching '\(body.project ?? "")'"))
                }
                supervisor.removeProject(id: project.id)
                return (200, try ok(PortlyAPI.ActionResponse(affected: [project.id], message: "Removed project \(project.name)")))

            case ("POST", "/servers/add"):
                let body: PortlyAPI.AddServerRequest = try request.decode()
                guard let project = supervisor.resolveProject(body.project) else {
                    return (404, try fail("No project matching '\(body.project)'"))
                }
                if project.servers.contains(where: { $0.name.caseInsensitiveCompare(body.name) == .orderedSame }) {
                    return (400, try fail("\(project.name) already has a server named '\(body.name)'"))
                }
                let server = ServerConfig(
                    name: body.name,
                    command: body.command,
                    port: body.port,
                    directory: body.directory,
                    env: body.env ?? [:],
                    healthURL: body.healthURL,
                    healthStatus: body.healthStatus,
                    autoRestart: body.autoRestart ?? true
                )
                supervisor.addServer(projectID: project.id, server: server)
                if body.start == true { supervisor.start(serverID: server.id) }
                return (200, try ok(server))

            case ("POST", "/servers/update"):
                let body: PortlyAPI.UpdateServerRequest = try request.decode()
                guard let runtime = supervisor.resolveServer(body.server) else {
                    return (404, try fail("No server matching '\(body.server)'"))
                }
                var config = runtime.config
                if let v = body.name { config.name = v }
                if let v = body.command { config.command = v }
                if let v = body.port { config.port = v }
                if let v = body.directory { config.directory = v }
                if let v = body.env { config.env = v }
                if let v = body.healthURL { config.healthURL = v }
                if let v = body.healthStatus { config.healthStatus = v }
                if let v = body.autoRestart { config.autoRestart = v }
                supervisor.updateServer(config)
                return (200, try ok(config))

            case ("POST", "/servers/remove"):
                let body: PortlyAPI.RemoveRequest = try request.decode()
                guard let query = body.server, let runtime = supervisor.resolveServer(query) else {
                    return (404, try fail("No server matching '\(body.server ?? "")'"))
                }
                let name = runtime.config.name
                supervisor.removeServer(id: runtime.id)
                return (200, try ok(PortlyAPI.ActionResponse(affected: [runtime.id], message: "Removed server \(name)")))

            case ("GET", "/ports"):
                guard let raw = request.query["port"], let port = Int(raw) else {
                    return (400, try fail("Missing ?port="))
                }
                return (200, try ok(PortlyAPI.PortQueryResponse(port: port, occupant: supervisor.occupant(of: port))))

            case ("POST", "/ports/kill"):
                let body: PortlyAPI.KillPortRequest = try request.decode()
                guard let occupant = supervisor.occupant(of: body.port) else {
                    return (404, try fail("Nothing is listening on port \(body.port)"))
                }
                PortInspector.kill(pid: occupant.pid)
                return (200, try ok(PortlyAPI.ActionResponse(
                    affected: [String(occupant.pid)],
                    message: "Sent SIGTERM to \(occupant.command) (pid \(occupant.pid)) on port \(body.port)"
                )))

            case ("POST", "/open"):
                WindowOpener.openMainWindow()
                return (200, try ok(PortlyAPI.ActionResponse(affected: [], message: "Opened Portly")))

            case ("POST", "/quit"):
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NSApplication.shared.terminate(nil)
                }
                return (200, try ok(PortlyAPI.ActionResponse(affected: [], message: "Quitting Portly")))

            default:
                return (404, try fail("Unknown endpoint \(request.method) \(request.path)"))
            }
        } catch let error as HTTPRequest.DecodeError {
            return (400, (try? fail(error.message)) ?? Data())
        } catch {
            return (500, (try? fail(error.localizedDescription)) ?? Data())
        }
    }

    private func act(_ path: String, _ target: PortlyAPI.TargetRequest) throws -> PortlyAPI.ActionResponse {
        let verb = String(path.dropFirst())

        if let query = target.server {
            guard let runtime = supervisor.resolveServer(query) else {
                throw HTTPRequest.DecodeError(message: "No server matching '\(query)'")
            }
            apply(verb, to: runtime)
            return PortlyAPI.ActionResponse(affected: [runtime.id], message: "\(verb) \(runtime.config.name)")
        }

        if let query = target.project {
            guard let project = supervisor.resolveProject(query) else {
                throw HTTPRequest.DecodeError(message: "No project matching '\(query)'")
            }
            let runtimes = supervisor.runtimes(inProject: project.id)
            runtimes.forEach { apply(verb, to: $0) }
            return PortlyAPI.ActionResponse(
                affected: runtimes.map(\.id),
                message: "\(verb) \(runtimes.count) server(s) in \(project.name)"
            )
        }

        // No target: act on everything. Only meaningful for stop.
        let all = Array(supervisor.runtimes.values)
        all.forEach { apply(verb, to: $0) }
        return PortlyAPI.ActionResponse(affected: all.map(\.id), message: "\(verb) all servers")
    }

    private func apply(_ verb: String, to runtime: ServerRuntime) {
        switch verb {
        case "start": runtime.start()
        case "stop": runtime.stop()
        case "restart": runtime.restart()
        default: break
        }
    }

    // MARK: - Encoding

    private func ok<T: Codable>(_ value: T) throws -> Data {
        try PortlyAPI.encoder().encode(PortlyAPI.Envelope(ok: true, data: value))
    }

    private func fail(_ message: String) throws -> Data {
        try PortlyAPI.encoder().encode(PortlyAPI.Envelope<PortlyAPI.Empty>(ok: false, data: nil, error: message))
    }
}

// MARK: - Minimal HTTP request parser

struct HTTPRequest {
    struct DecodeError: Error {
        let message: String
    }

    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    init?(_ raw: Data) {
        guard let headerEnd = HTTPRequest.range(of: Data("\r\n\r\n".utf8), in: raw) else { return nil }
        let headerData = raw.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        method = String(parts[0])
        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1)
        path = String(split[0])
        if split.count > 1 {
            var parsed: [String: String] = [:]
            for pair in split[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = kv.first else { continue }
                let value = kv.count > 1 ? String(kv[1]) : ""
                parsed[String(key)] = value.removingPercentEncoding ?? value
            }
            query = parsed
        } else {
            query = [:]
        }

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }

        let bodyStart = headerEnd.upperBound
        let available = raw.count - bodyStart
        // Wait for the full body before handling the request.
        guard available >= contentLength else { return nil }
        body = contentLength > 0 ? raw.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
    }

    func decode<T: Codable>() throws -> T {
        guard !body.isEmpty else {
            throw DecodeError(message: "Missing JSON body")
        }
        do {
            return try PortlyAPI.decoder().decode(T.self, from: body)
        } catch {
            throw DecodeError(message: "Invalid JSON body: \(error.localizedDescription)")
        }
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Int>? {
        guard haystack.count >= needle.count else { return nil }
        let bytes = [UInt8](haystack)
        let pattern = [UInt8](needle)
        var i = 0
        while i <= bytes.count - pattern.count {
            if Array(bytes[i..<(i + pattern.count)]) == pattern {
                return i..<(i + pattern.count)
            }
            i += 1
        }
        return nil
    }
}
