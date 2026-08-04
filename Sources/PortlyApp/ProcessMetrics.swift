import Darwin
import Foundation

struct ManagedProcessSnapshot: Identifiable, Equatable {
    let pid: Int32
    let parentPID: Int32
    let command: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let residentMemoryBytes: UInt64

    var id: Int32 { pid }

    var displayName: String {
        ProcessDisplayName.make(command: command)
    }
}

struct ExternalProcessSnapshot: Identifiable, Equatable {
    let pid: Int32
    let parentPID: Int32
    let command: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let residentMemoryBytes: UInt64
    let parentCommand: String?
    let workingDirectory: String?
    let listeningPorts: [Int]
    /// The dev launcher to stop when this is only a heavy child. For standalone
    /// processes this is the process itself.
    let terminationPID: Int32
    let terminationCommand: String

    var id: Int32 { pid }
    var displayName: String { ProcessDisplayName.make(command: command) }

    func preservingDetails(from previous: ExternalProcessSnapshot?) -> ExternalProcessSnapshot {
        guard let previous, previous.command == command else { return self }
        return ExternalProcessSnapshot(
            pid: pid,
            parentPID: parentPID,
            command: command,
            cpuPercent: cpuPercent,
            memoryBytes: memoryBytes,
            residentMemoryBytes: residentMemoryBytes,
            parentCommand: parentCommand ?? previous.parentCommand,
            workingDirectory: workingDirectory ?? previous.workingDirectory,
            listeningPorts: listeningPorts.isEmpty ? previous.listeningPorts : listeningPorts,
            terminationPID: terminationPID,
            terminationCommand: terminationCommand
        )
    }

    init(
        pid: Int32,
        parentPID: Int32,
        command: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        residentMemoryBytes: UInt64,
        parentCommand: String? = nil,
        workingDirectory: String? = nil,
        listeningPorts: [Int] = [],
        terminationPID: Int32? = nil,
        terminationCommand: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.command = command
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.residentMemoryBytes = residentMemoryBytes
        self.parentCommand = parentCommand
        self.workingDirectory = workingDirectory
        self.listeningPorts = listeningPorts
        self.terminationPID = terminationPID ?? pid
        self.terminationCommand = terminationCommand ?? command
    }
}

struct ProcessMetricsSample: Equatable {
    let managedByRoot: [Int32: ProcessMetrics]
    let externalProcesses: [ExternalProcessSnapshot]
}

private enum ProcessDisplayName {
    static func make(command: String) -> String {
        // `ps` does not quote paths containing spaces. Recover macOS app names
        // before falling back to the first shell token.
        if let appRange = command.range(of: ".app/Contents/") {
            let appPath = String(command[..<appRange.lowerBound])
            if let slash = appPath.lastIndex(of: "/") {
                return String(appPath[appPath.index(after: slash)...])
            }
            return appPath
        }

        guard let executable = command.split(separator: " ").first else { return "process" }
        return URL(fileURLWithPath: String(executable)).lastPathComponent
    }
}

struct ProcessMetrics: Equatable {
    let cpuPercent: Double
    /// Physical footprint owned by the process group. Unlike RSS, this keeps
    /// compressed and swapped dirty pages attributed to the workload.
    let memoryBytes: UInt64
    /// Pages from the process group that are currently resident in RAM.
    let residentMemoryBytes: UInt64
    let processCount: Int
    let processes: [ManagedProcessSnapshot]

    var cpuPressure: ResourcePressure {
        if cpuPercent < 35 { return .light }
        if cpuPercent < 80 { return .moderate }
        return .high
    }

    var memoryPressure: ResourcePressure {
        if memoryBytes < 256 * 1_024 * 1_024 { return .light }
        if memoryBytes < 1_024 * 1_024 * 1_024 { return .moderate }
        return .high
    }
}

enum ResourcePressure {
    case light
    case moderate
    case high

    var label: String {
        switch self {
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .high: return "High"
        }
    }
}

/// Samples the process trees Portly owns. A managed command is normally a small
/// shell that starts pnpm, Vite, Next.js and other children. Some launchers
/// create new process groups, so ancestry—not PGID—is the durable ownership
/// boundary for resource attribution.
enum ProcessMetricsSampler {
    static func sample(
        rootProcessIDs: Set<Int32>,
        includeExternalDetails: Bool = true
    ) -> ProcessMetricsSample {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "uid=,pid=,ppid=,rss=,%cpu=,command="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ProcessMetricsSample(managedByRoot: [:], externalProcesses: [])
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return ProcessMetricsSample(managedByRoot: [:], externalProcesses: [])
        }

        struct Record {
            let userID: UInt32
            let pid: Int32
            let parentPID: Int32
            let residentKilobytes: UInt64
            let cpuPercent: Double
            let command: String
        }

        var records: [Record] = []
        var parentByPID: [Int32: Int32] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(
                maxSplits: 5,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 6,
                  let userID = UInt32(fields[0]),
                  let pid = Int32(fields[1]),
                  let parentPID = Int32(fields[2]),
                  let residentKilobytes = UInt64(fields[3]),
                  let cpuPercent = Double(fields[4]) else { continue }

            records.append(
                Record(
                    userID: userID,
                    pid: pid,
                    parentPID: parentPID,
                    residentKilobytes: residentKilobytes,
                    cpuPercent: cpuPercent,
                    command: String(fields[5])
                )
            )
            parentByPID[pid] = parentPID
        }
        let recordByPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })

        func ownerRoot(for pid: Int32) -> Int32? {
            var current = pid
            var visited = Set<Int32>()
            while current > 0, visited.insert(current).inserted {
                if rootProcessIDs.contains(current) { return current }
                guard let parent = parentByPID[current] else { return nil }
                current = parent
            }
            return nil
        }

        struct Totals {
            var cpuPercent = 0.0
            var footprintBytes: UInt64 = 0
            var residentBytes: UInt64 = 0
            var processCount = 0
            var processes: [ManagedProcessSnapshot] = []
        }

        var totals: [Int32: Totals] = [:]
        var managedProcessIDs = Set<Int32>()
        for record in records {
            guard let root = ownerRoot(for: record.pid) else { continue }
            managedProcessIDs.insert(record.pid)

            var group = totals[root, default: Totals()]
            group.cpuPercent += record.cpuPercent
            let rssBytes = record.residentKilobytes * 1_024
            let usage: (footprintBytes: UInt64, residentBytes: UInt64)
            if let sampledUsage = resourceUsage(pid: record.pid) {
                usage = sampledUsage
            } else {
                // A short-lived child can exit between `ps` and this call. RSS
                // remains a useful lower-bound fallback for that sample.
                usage = (rssBytes, rssBytes)
            }
            group.footprintBytes += usage.footprintBytes
            group.residentBytes += usage.residentBytes
            group.processCount += 1
            group.processes.append(
                ManagedProcessSnapshot(
                    pid: record.pid,
                    parentPID: record.parentPID,
                    command: record.command,
                    cpuPercent: record.cpuPercent,
                    memoryBytes: usage.footprintBytes,
                    residentMemoryBytes: usage.residentBytes
                )
            )
            totals[root] = group
        }

        let managedByRoot = totals.mapValues { total in
            ProcessMetrics(
                cpuPercent: total.cpuPercent,
                memoryBytes: total.footprintBytes,
                residentMemoryBytes: total.residentBytes,
                processCount: total.processCount,
                processes: total.processes.sorted { lhs, rhs in
                    if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
                    return lhs.pid < rhs.pid
                }
            )
        }

        // System-wide visibility is intentionally limited to the current
        // user's heaviest processes. That keeps the dashboard actionable,
        // avoids privileged/system daemons, and bounds sampling overhead.
        let currentUserID = getuid()
        let externalRecords = Array(records
            .filter {
                $0.userID == currentUserID
                    && $0.pid != getpid()
                    && !managedProcessIDs.contains($0.pid)
                    && $0.residentKilobytes >= 16 * 1_024
            }
            .sorted { lhs, rhs in
                if lhs.residentKilobytes != rhs.residentKilobytes {
                    return lhs.residentKilobytes > rhs.residentKilobytes
                }
                return lhs.pid < rhs.pid
            }
            .prefix(30))

        let topExternalIDs = Set(externalRecords.map(\.pid))
        let directories = includeExternalDetails
            ? PortInspector.workingDirectories(for: Set(externalRecords.flatMap { [$0.pid, $0.parentPID] }))
            : [:]
        let directListeningPorts = includeExternalDetails ? PortInspector.listenerPortsByPID() : [:]
        var listeningPortsByExternalPID: [Int32: Set<Int>] = [:]
        for (listenerPID, ports) in directListeningPorts {
            var current = listenerPID
            var visited = Set<Int32>()
            while current > 0, visited.insert(current).inserted {
                if topExternalIDs.contains(current) {
                    listeningPortsByExternalPID[current, default: []].formUnion(ports)
                }
                guard let parent = parentByPID[current] else { break }
                current = parent
            }
        }

        func isDevLauncher(_ command: String) -> Bool {
            let lower = command.lowercased()
            return lower.contains("pnpm dev")
                || lower.contains("pnpm run dev")
                || lower.contains("npm run dev")
                || lower.contains("yarn dev")
                || lower.contains("bun run dev")
                || lower.contains("next/dist/bin/next dev")
                || lower.contains("vite") && !lower.contains("helper")
        }

        func terminationTarget(for record: Record) -> Record {
            var selected = record
            var current = record
            var visited = Set<Int32>()
            while visited.insert(current.pid).inserted,
                  let parent = recordByPID[current.parentPID],
                  parent.userID == currentUserID {
                if isDevLauncher(parent.command) { selected = parent }
                current = parent
            }
            return selected
        }

        let externalProcesses = externalRecords
            .map { record in
                let rssBytes = record.residentKilobytes * 1_024
                let usage = resourceUsage(pid: record.pid) ?? (rssBytes, rssBytes)
                let target = terminationTarget(for: record)
                return ExternalProcessSnapshot(
                    pid: record.pid,
                    parentPID: record.parentPID,
                    command: record.command,
                    cpuPercent: record.cpuPercent,
                    memoryBytes: usage.footprintBytes,
                    residentMemoryBytes: usage.residentBytes,
                    parentCommand: recordByPID[record.parentPID]?.command,
                    workingDirectory: directories[record.pid] ?? directories[target.pid],
                    listeningPorts: Array(listeningPortsByExternalPID[record.pid] ?? []).sorted(),
                    terminationPID: target.pid,
                    terminationCommand: target.command
                )
            }
            .sorted { lhs, rhs in
                if lhs.residentMemoryBytes != rhs.residentMemoryBytes {
                    return lhs.residentMemoryBytes > rhs.residentMemoryBytes
                }
                return lhs.pid < rhs.pid
            }

        return ProcessMetricsSample(
            managedByRoot: managedByRoot,
            externalProcesses: externalProcesses
        )
    }

    private static func resourceUsage(pid: Int32) -> (footprintBytes: UInt64, residentBytes: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pid_rusage(
                pid,
                RUSAGE_INFO_V4,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            )
        }
        guard result == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_resident_size)
    }
}
