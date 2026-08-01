import Foundation

/// Every on-disk location Portly uses. Deliberately outside any app sandbox so
/// the config stays hand-editable and an agent can read it without the app running.
public enum PortlyPaths {
    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("portly", isDirectory: true)
    }

    public static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    public static var logsDirectory: URL {
        configDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public static func logFile(forServer id: String) -> URL {
        logsDirectory.appendingPathComponent("\(id).log")
    }

    public static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}
