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
    static func sample(rootProcessIDs: Set<Int32>) -> [Int32: ProcessMetrics] {
        guard !rootProcessIDs.isEmpty else { return [:] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss=,%cpu=,command="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }

        struct Record {
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
                maxSplits: 4,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 5,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]),
                  let residentKilobytes = UInt64(fields[2]),
                  let cpuPercent = Double(fields[3]) else { continue }

            records.append(
                Record(
                    pid: pid,
                    parentPID: parentPID,
                    residentKilobytes: residentKilobytes,
                    cpuPercent: cpuPercent,
                    command: String(fields[4])
                )
            )
            parentByPID[pid] = parentPID
        }

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
        for record in records {
            guard let root = ownerRoot(for: record.pid) else { continue }

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

        return totals.mapValues { total in
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
