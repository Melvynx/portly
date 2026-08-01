import Foundation
import PortlyCore

/// Finds who is listening on a port. Portly never kills anything on its own:
/// this only reports, and the kill is an explicit user or agent action.
enum PortInspector {
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

    @discardableResult
    static func kill(pid: Int32, force: Bool = false) -> Bool {
        Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0
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
