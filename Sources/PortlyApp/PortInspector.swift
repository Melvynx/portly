import Foundation
import PortlyCore

/// Finds who is listening on a port. Portly never kills anything on its own:
/// this only reports, and the kill is an explicit user or agent action.
enum PortInspector {
    struct StopOutcome: Equatable {
        let description: String
        let processID: Int32?
        let dockerContainer: DockerPublishedContainer?
    }

    enum StopError: LocalizedError {
        case portFree
        case listenerChanged
        case processRefused(Int32)
        case docker(String)

        var errorDescription: String? {
            switch self {
            case .portFree: return "The port is already free."
            case .listenerChanged: return "The listener changed before Portly could stop it. Refresh and try again."
            case .processRefused(let pid): return "Process \(pid) refused the stop request."
            case .docker(let message): return message
            }
        }
    }

    struct Listener: Identifiable, Hashable {
        let port: Int
        let pid: Int32
        let command: String
        let user: String
        let workingDirectory: String?

        var id: String { "\(pid):\(port)" }
    }

    /// Every process currently accepting TCP connections, deduplicated across
    /// IPv4 and IPv6 sockets. Working directories let the UI turn generic
    /// process names such as `node` into useful application groups.
    static func listeners() -> [Listener] {
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcLn"])
        guard !output.isEmpty else { return [] }

        var records: [(port: Int, pid: Int32, command: String, user: String)] = []
        var pid: Int32?
        var command = ""
        var user = ""
        var ports = Set<Int>()

        func appendCurrentProcess() {
            guard let pid else { return }
            for port in ports {
                records.append((port, pid, command.isEmpty ? "unknown" : command, user))
            }
        }

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                appendCurrentProcess()
                pid = Int32(value)
                command = ""
                user = ""
                ports.removeAll(keepingCapacity: true)
            case "c": command = value
            case "L": user = value
            case "n":
                if let port = portNumber(from: value) { ports.insert(port) }
            default: break
            }
        }
        appendCurrentProcess()

        let directories = workingDirectories(for: Set(records.map(\.pid)))
        return records
            .map {
                Listener(
                    port: $0.port,
                    pid: $0.pid,
                    command: $0.command,
                    user: $0.user,
                    workingDirectory: directories[$0.pid]
                )
            }
            .sorted { lhs, rhs in
                if lhs.port == rhs.port { return lhs.pid < rhs.pid }
                return lhs.port < rhs.port
            }
    }

    static func occupant(of port: Int) -> (pid: Int32, command: String, user: String)? {
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-FpcLn"])
        guard !output.isEmpty else { return nil }

        var pid: Int32?
        var command = ""
        var user = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                // A second process block means we already have the first listener.
                if pid != nil { return finish(pid, command, user) }
                pid = Int32(value)
            case "c": command = value
            case "L": user = value
            default: break
            }
        }
        return finish(pid, command, user)
    }

    private static func finish(_ pid: Int32?, _ command: String, _ user: String) -> (Int32, String, String)? {
        guard let pid else { return nil }
        return (pid, command.isEmpty ? "unknown" : command, user)
    }

    /// True when something is accepting TCP connections on the port.
    static func isListening(port: Int) -> Bool {
        occupant(of: port) != nil
    }

    /// Lightweight listener map used by the resource sampler to tell whether a
    /// heavy process (or one of its descendants) is an actual server that can
    /// be moved under Portly.
    static func listenerPortsByPID() -> [Int32: Set<Int>] {
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        guard !output.isEmpty else { return [:] }

        var result: [Int32: Set<Int>] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "n":
                if let pid, let port = portNumber(from: value) {
                    result[pid, default: []].insert(port)
                }
            default: break
            }
        }
        return result
    }

    @discardableResult
    static func kill(pid: Int32, force: Bool = false) -> Bool {
        Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    /// Stops the real owner of a host port. Docker Desktop exposes every
    /// published container through one global backend process, so killing the
    /// listener PID would restart or destabilize Docker itself. In that case we
    /// stop only the container publishing this exact port.
    static func stopOccupant(
        of port: Int,
        expectedPID: Int32? = nil
    ) -> Result<StopOutcome, StopError> {
        guard let occupant = occupant(of: port) else { return .failure(.portFree) }
        if let expectedPID, occupant.pid != expectedPID { return .failure(.listenerChanged) }

        if let container = DockerPortInspector.container(publishing: port) {
            switch DockerPortInspector.stop(container) {
            case .success:
                return .success(
                    StopOutcome(
                        description: "Docker container \(container.displayName)",
                        processID: nil,
                        dockerContainer: container
                    )
                )
            case .failure(let error):
                return .failure(.docker(error.localizedDescription))
            }
        }

        guard kill(pid: occupant.pid) else { return .failure(.processRefused(occupant.pid)) }
        return .success(
            StopOutcome(
                description: "\(occupant.command) (pid \(occupant.pid))",
                processID: occupant.pid,
                dockerContainer: nil
            )
        )
    }

    private static func portNumber(from endpoint: String) -> Int? {
        let localEndpoint = endpoint.split(separator: "->", maxSplits: 1).first.map(String.init) ?? endpoint
        guard let separator = localEndpoint.lastIndex(of: ":") else { return nil }
        let value = localEndpoint[localEndpoint.index(after: separator)...]
        guard let port = Int(value), (1...65_535).contains(port) else { return nil }
        return port
    }

    static func workingDirectories(for pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.sorted().map(String.init).joined(separator: ",")
        let output = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-Fpn"])

        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "n":
                if let pid { result[pid] = value }
            default: break
            }
        }
        return result
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
