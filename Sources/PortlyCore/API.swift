import Foundation

/// Wire format shared by the app's local HTTP server and the `portly` CLI.
public enum PortlyAPI {
    public static let bundleIdentifier = "dev.portly.app"

    public struct Envelope<T: Codable>: Codable {
        public var ok: Bool
        public var data: T?
        public var error: String?

        public init(ok: Bool, data: T? = nil, error: String? = nil) {
            self.ok = ok
            self.data = data
            self.error = error
        }
    }

    public struct Empty: Codable { public init() {} }

    public struct TargetRequest: Codable {
        /// Server id/name, or "project/server". Mutually exclusive with `project`.
        public var server: String?
        /// Project id or name. Acts on every server in the project.
        public var project: String?

        public init(server: String? = nil, project: String? = nil) {
            self.server = server
            self.project = project
        }
    }

    public struct AddProjectRequest: Codable {
        public var name: String
        public var root: String
        public var icon: String?
        public var color: String?

        public init(name: String, root: String, icon: String? = nil, color: String? = nil) {
            self.name = name
            self.root = root
            self.icon = icon
            self.color = color
        }
    }

    public struct AddServerRequest: Codable {
        public var project: String
        public var name: String
        public var command: String
        public var port: Int?
        public var directory: String?
        public var env: [String: String]?
        public var healthURL: String?
        public var healthStatus: Int?
        public var autoRestart: Bool?
        /// Start the server immediately after adding it.
        public var start: Bool?

        public init(
            project: String, name: String, command: String, port: Int? = nil,
            directory: String? = nil, env: [String: String]? = nil,
            healthURL: String? = nil, healthStatus: Int? = nil,
            autoRestart: Bool? = nil, start: Bool? = nil
        ) {
            self.project = project
            self.name = name
            self.command = command
            self.port = port
            self.directory = directory
            self.env = env
            self.healthURL = healthURL
            self.healthStatus = healthStatus
            self.autoRestart = autoRestart
            self.start = start
        }
    }

    public struct UpdateServerRequest: Codable {
        public var server: String
        public var name: String?
        public var command: String?
        public var port: Int?
        public var directory: String?
        public var env: [String: String]?
        public var healthURL: String?
        public var healthStatus: Int?
        public var autoRestart: Bool?

        public init(server: String) { self.server = server }
    }

    public struct RemoveRequest: Codable {
        public var server: String?
        public var project: String?

        public init(server: String? = nil, project: String? = nil) {
            self.server = server
            self.project = project
        }
    }

    public struct LogsResponse: Codable {
        public var server: String
        public var lines: [String]

        public init(server: String, lines: [String]) {
            self.server = server
            self.lines = lines
        }
    }

    public struct PortQueryResponse: Codable {
        public var port: Int
        public var occupant: PortOccupant?

        public init(port: Int, occupant: PortOccupant?) {
            self.port = port
            self.occupant = occupant
        }
    }

    public struct KillPortRequest: Codable {
        public var port: Int
        public init(port: Int) { self.port = port }
    }

    public struct ActionResponse: Codable {
        public var affected: [String]
        public var message: String

        public init(affected: [String], message: String) {
            self.affected = affected
            self.message = message
        }
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
