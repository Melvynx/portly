import Foundation

struct DockerPublishedContainer: Equatable {
    let id: String
    let name: String
    let composeProject: String?
    let composeService: String?

    var shortID: String { String(id.prefix(12)) }

    var displayName: String {
        if let composeProject, let composeService {
            return "\(composeProject) / \(composeService)"
        }
        return name
    }
}

enum DockerPortInspector {
    enum DockerError: LocalizedError {
        case unavailable
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Docker CLI is unavailable, so Portly cannot identify the container safely."
            case .commandFailed(let message):
                return message
            }
        }
    }

    static func container(publishing port: Int) -> DockerPublishedContainer? {
        guard let executable = dockerExecutable() else { return nil }
        let listed = run(
            executable,
            ["ps", "--filter", "publish=\(port)", "--format", "{{.ID}}"]
        )
        guard listed.status == 0 else { return nil }
        let ids = String(decoding: listed.output, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !ids.isEmpty else { return nil }

        let inspected = run(executable, ["inspect"] + ids)
        guard inspected.status == 0 else { return nil }
        return try? parseInspectResponse(inspected.output, publishing: port)
    }

    static func stop(_ container: DockerPublishedContainer) -> Result<Void, DockerError> {
        guard let executable = dockerExecutable() else { return .failure(.unavailable) }
        let result = run(executable, ["stop", "--time", "10", container.id])
        guard result.status == 0 else {
            let output = String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = output.isEmpty ? "Docker could not stop \(container.displayName)." : output
            return .failure(.commandFailed(detail))
        }
        return .success(())
    }

    static func parseInspectResponse(
        _ data: Data,
        publishing port: Int
    ) throws -> DockerPublishedContainer? {
        let containers = try JSONDecoder().decode([InspectContainer].self, from: data)
        for container in containers {
            let publishesPort = container.networkSettings.ports.values.contains { bindings in
                (bindings ?? []).contains { Int($0.hostPort) == port }
            }
            guard publishesPort else { continue }
            let labels = container.config.labels ?? [:]
            return DockerPublishedContainer(
                id: container.id,
                name: container.name.hasPrefix("/") ? String(container.name.dropFirst()) : container.name,
                composeProject: labels["com.docker.compose.project"],
                composeService: labels["com.docker.compose.service"]
            )
        }
        return nil
    }

    private struct InspectContainer: Decodable {
        let id: String
        let name: String
        let config: Config
        let networkSettings: NetworkSettings

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case config = "Config"
            case networkSettings = "NetworkSettings"
        }
    }

    private struct Config: Decodable {
        let labels: [String: String]?

        enum CodingKeys: String, CodingKey { case labels = "Labels" }
    }

    private struct NetworkSettings: Decodable {
        let ports: [String: [PortBinding]?]

        enum CodingKeys: String, CodingKey { case ports = "Ports" }
    }

    private struct PortBinding: Decodable {
        let hostPort: String

        enum CodingKeys: String, CodingKey { case hostPort = "HostPort" }
    }

    private static func dockerExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "\(home)/.docker/bin/docker",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private static func run(_ executable: URL, _ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return (-1, Data()) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
