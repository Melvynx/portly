import Darwin
import Foundation

enum ExternalProcessController {
    struct ProcessRecord: Equatable {
        let pid: Int32
        let parentPID: Int32
        let command: String
    }

    struct StopResult: Equatable {
        let targetPID: Int32
        let terminatedPIDs: [Int32]
    }

    enum StopError: LocalizedError, Equatable {
        case processExited
        case pidReused
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .processExited:
                return "The process already exited. The dashboard will refresh automatically."
            case .pidReused:
                return "The PID now belongs to a different command, so Portly refused to stop it."
            case .permissionDenied:
                return "macOS refused the stop request. Check the process permissions or use Activity Monitor."
            }
        }
    }

    static func stop(_ snapshot: ExternalProcessSnapshot) -> Result<StopResult, StopError> {
        stop(snapshot, currentProcesses: liveProcesses(), sendTerm: sendTerm)
    }

    static func stop(
        _ snapshot: ExternalProcessSnapshot,
        currentProcesses: [ProcessRecord],
        sendTerm: (Int32) -> Bool
    ) -> Result<StopResult, StopError> {
        guard let target = currentProcesses.first(where: { $0.pid == snapshot.terminationPID }) else {
            return .failure(.processExited)
        }
        guard target.command == snapshot.terminationCommand else {
            return .failure(.pidReused)
        }

        let childrenByParent = Dictionary(grouping: currentProcesses, by: \.parentPID)
        var descendants: [Int32] = []
        var queue = childrenByParent[target.pid] ?? []
        while !queue.isEmpty {
            let child = queue.removeFirst()
            descendants.append(child.pid)
            queue.append(contentsOf: childrenByParent[child.pid] ?? [])
        }

        // Stop the launcher first so it cannot respawn a child while the rest
        // of the tree receives SIGTERM. No SIGKILL is sent automatically.
        guard sendTerm(target.pid) else { return .failure(.permissionDenied) }
        for pid in descendants {
            _ = sendTerm(pid)
        }

        return .success(
            StopResult(targetPID: target.pid, terminatedPIDs: [target.pid] + descendants)
        )
    }

    static func liveProcesses() -> [ProcessRecord] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "uid=,pid=,ppid=,command="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        let currentUserID = getuid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(
                maxSplits: 3,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 4,
                  let userID = UInt32(fields[0]), userID == currentUserID,
                  let pid = Int32(fields[1]),
                  let parentPID = Int32(fields[2]) else { return nil }
            return ProcessRecord(pid: pid, parentPID: parentPID, command: String(fields[3]))
        }
    }

    private static func sendTerm(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, SIGTERM) == 0 { return true }
        // A descendant can exit naturally after its parent receives SIGTERM.
        return errno == ESRCH
    }
}
