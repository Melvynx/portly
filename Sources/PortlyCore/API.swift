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

    public struct OpenRequest: Codable {
        public var destination: String?
        public init(destination: String? = nil) { self.destination = destination }
    }

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
        public var memoryLimitMode: MemoryLimitMode?
        public var memoryLimitBytes: UInt64?

        public init(
            name: String,
            root: String,
            icon: String? = nil,
            color: String? = nil,
            memoryLimitMode: MemoryLimitMode? = nil,
            memoryLimitBytes: UInt64? = nil
        ) {
            self.name = name
            self.root = root
            self.icon = icon
            self.color = color
            self.memoryLimitMode = memoryLimitMode
            self.memoryLimitBytes = memoryLimitBytes
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
        public var actions: [ServerAction]?
        /// Nil inherits the global default, 0 turns idle stops off.
        public var idleTimeoutSeconds: Int?
        /// Start the server immediately after adding it.
        public var start: Bool?

        public init(
            project: String, name: String, command: String, port: Int? = nil,
            directory: String? = nil, env: [String: String]? = nil,
            healthURL: String? = nil, healthStatus: Int? = nil,
            autoRestart: Bool? = nil, actions: [ServerAction]? = nil,
            idleTimeoutSeconds: Int? = nil, start: Bool? = nil
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
            self.actions = actions
            self.idleTimeoutSeconds = idleTimeoutSeconds
            self.start = start
        }
    }

    public struct RunServerActionRequest: Codable {
        public var server: String
        public var action: String
        public var timeoutSeconds: Int?

        public init(server: String, action: String, timeoutSeconds: Int? = nil) {
            self.server = server
            self.action = action
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public struct RunTemporaryRequest: Codable {
        public var name: String
        public var command: String
        public var directory: String
        public var port: Int?
        public var env: [String: String]?
        public var healthURL: String?
        public var healthStatus: Int?
        public var timeoutSeconds: Int?

        public init(
            name: String,
            command: String,
            directory: String,
            port: Int? = nil,
            env: [String: String]? = nil,
            healthURL: String? = nil,
            healthStatus: Int? = nil,
            timeoutSeconds: Int? = nil
        ) {
            self.name = name
            self.command = command
            self.directory = directory
            self.port = port
            self.env = env
            self.healthURL = healthURL
            self.healthStatus = healthStatus
            self.timeoutSeconds = timeoutSeconds
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
        public var actions: [ServerAction]?

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

    public struct TakeOverRequest: Codable {
        public var server: String
        public init(server: String) { self.server = server }
    }

    public struct UpdateMemoryLimitRequest: Codable {
        public var project: String?
        public var mode: MemoryLimitMode
        public var bytes: UInt64?

        public init(project: String? = nil, mode: MemoryLimitMode, bytes: UInt64? = nil) {
            self.project = project
            self.mode = mode
            self.bytes = bytes
        }
    }

    public struct UpdateIdleTimeoutRequest: Codable {
        /// Omit to change the global default.
        public var server: String?
        /// 0 turns idle stops off. Nil is only valid with `server` and inherits the global default.
        public var seconds: Int?

        public init(server: String? = nil, seconds: Int?) {
            self.server = server
            self.seconds = seconds
        }
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
