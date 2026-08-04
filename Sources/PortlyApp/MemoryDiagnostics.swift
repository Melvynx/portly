import Foundation

enum MemoryDiagnosticSeverity: Int, Comparable, Equatable {
    case healthy = 0
    case notice = 1
    case warning = 2
    case critical = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .notice: return "Review"
        case .warning: return "High"
        case .critical: return "Critical"
        }
    }
}

struct MemoryServerDiagnosticSnapshot: Equatable {
    let id: String
    let projectID: String
    let fullName: String
    let metrics: ProcessMetrics
}

struct MemoryDiagnostic: Identifiable, Equatable {
    let id: String
    let severity: MemoryDiagnosticSeverity
    let title: String
    let summary: String
    let fix: String
    let serverID: String?
    let processID: Int32?
}

enum MemoryDiagnosticsEngine {
    private static let mebibyte = UInt64(1_048_576)
    private static let gibibyte = UInt64(1_073_741_824)

    static func analyze(
        servers: [MemoryServerDiagnosticSnapshot],
        projectHistory: [ProjectResourceHistoryPoint],
        externalProcesses: [ExternalProcessSnapshot],
        physicalMemoryBytes: UInt64
    ) -> [MemoryDiagnostic] {
        let physicalMemory = max(physicalMemoryBytes, 8 * gibibyte)
        let highServerThreshold = max(gibibyte, min(2 * gibibyte, physicalMemory / 10))
        let criticalServerThreshold = max(2 * gibibyte, min(4 * gibibyte, physicalMemory / 5))
        let largeProcessThreshold = max(512 * mebibyte, min(1_536 * mebibyte, physicalMemory / 16))
        let externalThreshold = max(gibibyte, min(2 * gibibyte, physicalMemory / 12))

        var diagnostics: [MemoryDiagnostic] = []

        for server in servers.sorted(by: { $0.metrics.memoryBytes > $1.metrics.memoryBytes }) {
            let memory = server.metrics.memoryBytes
            if memory >= highServerThreshold {
                let severity: MemoryDiagnosticSeverity = memory >= criticalServerThreshold ? .critical : .warning
                let process = server.metrics.processes.max(by: { $0.memoryBytes < $1.memoryBytes })
                diagnostics.append(
                    MemoryDiagnostic(
                        id: "server-\(server.id)",
                        severity: severity,
                        title: "\(server.fullName) owns \(bytes(memory))",
                        summary: process.map {
                            "\($0.displayName) is the largest child at \(bytes($0.memoryBytes)). The total includes compressed or swapped pages still owned by this server."
                        } ?? "This server is using an unusually large share of the machine's memory.",
                        fix: advice(for: process?.command ?? "", managed: true),
                        serverID: server.id,
                        processID: process?.pid
                    )
                )
                continue
            }

            if let process = server.metrics.processes.first(where: { $0.memoryBytes >= largeProcessThreshold }) {
                diagnostics.append(
                    MemoryDiagnostic(
                        id: "process-\(server.id)-\(process.pid)",
                        severity: .notice,
                        title: "Large \(process.displayName) process",
                        summary: "PID \(process.pid) owns \(bytes(process.memoryBytes)) inside \(server.fullName).",
                        fix: advice(for: process.command, managed: true),
                        serverID: server.id,
                        processID: process.pid
                    )
                )
            }
        }

        diagnostics.append(contentsOf: growthDiagnostics(servers: servers, history: projectHistory))

        let managedPIDs = Set(servers.flatMap { $0.metrics.processes.map(\.pid) })
        let heavyExternal = externalProcesses
            .filter { !managedPIDs.contains($0.pid) && $0.memoryBytes >= externalThreshold }
            .prefix(3)
        for process in heavyExternal {
            diagnostics.append(
                MemoryDiagnostic(
                    id: "external-\(process.pid)",
                    severity: process.memoryBytes >= externalThreshold * 2 ? .warning : .notice,
                    title: "\(process.displayName) is heavy outside Portly",
                    summary: "PID \(process.pid) owns \(bytes(process.memoryBytes)) and uses \(bytes(process.residentMemoryBytes)) of RAM. Portly will not stop it automatically.",
                    fix: advice(for: process.command, managed: false),
                    serverID: nil,
                    processID: process.pid
                )
            )
        }

        diagnostics.append(contentsOf: duplicateDevProcessDiagnostics(externalProcesses))

        if diagnostics.isEmpty {
            return [
                MemoryDiagnostic(
                    id: "healthy",
                    severity: .healthy,
                    title: "Memory use looks healthy",
                    summary: "No managed server is above its machine-adjusted limit and no sustained growth is visible in the recent window.",
                    fix: "Keep this dashboard open while reproducing a slowdown. Portly will surface a new recommendation as soon as the pattern becomes significant.",
                    serverID: nil,
                    processID: nil
                ),
            ]
        }

        return diagnostics
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.id < rhs.id
            }
            .prefix(8)
            .map { $0 }
    }

    private static func growthDiagnostics(
        servers: [MemoryServerDiagnosticSnapshot],
        history: [ProjectResourceHistoryPoint]
    ) -> [MemoryDiagnostic] {
        let serversByProject = Dictionary(grouping: servers, by: \.projectID)
        return Dictionary(grouping: history, by: \.projectID).compactMap { projectID, points in
            let sorted = points.sorted { $0.timestamp < $1.timestamp }
            guard sorted.count >= 8,
                  let first = sorted.first,
                  let last = sorted.last else { return nil }

            let duration = last.timestamp.timeIntervalSince(first.timestamp)
            guard duration >= 20 else { return nil }

            let windowSize = max(2, sorted.count / 4)
            let baseline = median(sorted.prefix(windowSize).map(\.footprintBytes))
            let recent = median(sorted.suffix(windowSize).map(\.footprintBytes))
            guard recent > baseline else { return nil }

            let growth = recent - baseline
            let requiredGrowth = max(256 * mebibyte, baseline / 3)
            let bytesPerSecond = Double(growth) / duration
            guard growth >= requiredGrowth, bytesPerSecond >= Double(2 * mebibyte) else { return nil }

            let projectServers = serversByProject[projectID] ?? []
            let largestServer = projectServers.max { $0.metrics.memoryBytes < $1.metrics.memoryBytes }
            let largestProcess = largestServer?.metrics.processes.max { $0.memoryBytes < $1.memoryBytes }
            let severity: MemoryDiagnosticSeverity = growth >= 768 * mebibyte ? .critical : .warning

            return MemoryDiagnostic(
                id: "growth-\(projectID)",
                severity: severity,
                title: "\(last.projectName) keeps growing",
                summary: "Footprint rose by \(bytes(growth)) over \(duration.formatted(.number.precision(.fractionLength(0)))) seconds; the signal uses early and recent medians to ignore one-off build spikes.",
                fix: advice(for: largestProcess?.command ?? "", managed: true),
                serverID: largestServer?.id,
                processID: largestProcess?.pid
            )
        }
    }

    private static func duplicateDevProcessDiagnostics(
        _ processes: [ExternalProcessSnapshot]
    ) -> [MemoryDiagnostic] {
        let candidates = processes.compactMap { process -> (String, ExternalProcessSnapshot)? in
            guard let family = devFamily(command: process.command) else { return nil }
            return (family, process)
        }

        return Dictionary(grouping: candidates, by: { $0.0 }).compactMap { family, entries in
            guard entries.count >= 2 else { return nil }
            let total = entries.reduce(UInt64(0)) { $0 + $1.1.memoryBytes }
            guard total >= 768 * mebibyte else { return nil }
            let pids = entries.prefix(4).map { String($0.1.pid) }.joined(separator: ", ")
            return MemoryDiagnostic(
                id: "duplicate-\(family)",
                severity: .notice,
                title: "Multiple \(family) sessions run outside Portly",
                summary: "\(entries.count) related processes own \(bytes(total)) in total (PIDs \(pids)). Some may be stale or duplicate dev servers.",
                fix: "Close stale sessions, then register each persistent dev server in Portly so its full process tree can be stopped and monitored safely.",
                serverID: nil,
                processID: entries.first?.1.pid
            )
        }
    }

    static func advice(for command: String, managed: Bool) -> String {
        let lower = command.lowercased()
        let looksLikeDevProcess = lower.contains("node_modules")
            || lower.contains("next-server")
            || lower.contains("next dev")
            || lower.contains("vite")
            || lower.contains("pnpm")
            || lower.contains("npm run")
        let prefix: String
        if managed {
            prefix = "Restart the server to reclaim memory now. "
        } else if looksLikeDevProcess {
            prefix = "Stop the parent dev session, not only this child, then move it under Portly if it should stay running. "
        } else {
            prefix = "Quit or restart the owning app after saving your work. "
        }

        if lower.contains("next-server") || lower.contains("next/dist") || lower.contains("next dev") {
            return prefix + "If it grows again, check for duplicate Next.js dev sessions, import cycles, oversized source maps, and directories watched inside generated output."
        }
        if lower.contains("vite") {
            return prefix + "If it grows again, inspect Vite plugin caches and watcher loops, and exclude generated or build directories from file watching."
        }
        if lower.contains("tsserver") || lower.contains("typescript") {
            return prefix + "Restart the TypeScript service, then exclude generated folders and large artifacts from the workspace if usage climbs back."
        }
        if lower.contains("chrome") || lower.contains("chromium") {
            return prefix + "Close stale tabs and DevTools windows, then review extensions or tab memory if the same process becomes heavy again."
        }
        if lower.contains("docker") || lower.contains("com.docker") {
            return prefix + "Stop unused containers and set explicit container memory limits before restarting the workload."
        }
        if lower.contains("redis") {
            return prefix + "Inspect key count, eviction policy, and maxmemory; a restart only clears the symptom if the dataset immediately grows back."
        }
        if lower.contains("postgres") {
            return prefix + "Inspect shared_buffers, connection count, and expensive sessions before raising memory limits."
        }
        if lower.contains("node") || lower.contains("pnpm") || lower.contains("npm") || lower.contains("bun") {
            return prefix + "If usage returns, capture a heap snapshot with the runtime inspector and look for retained caches, listeners, or duplicated workers. Use a heap limit only as a safety rail."
        }
        return prefix + "If memory quickly returns, profile allocations and check for retained caches, background workers, or duplicate instances before increasing limits."
    }

    private static func devFamily(command: String) -> String? {
        let lower = command.lowercased()
        // Count launchers rather than workers. A single Next.js session normally
        // contains both `next dev` and `next-server`; treating both as sessions
        // would create a false duplicate warning.
        if lower.contains("next-server") { return nil }
        if lower.contains("next/dist") || lower.contains("next dev") { return "Next.js" }
        if lower.contains("vite") { return "Vite" }
        if lower.contains("convex dev") { return "Convex" }
        if lower.contains("pnpm") && lower.contains(" dev") { return "pnpm dev" }
        if lower.contains("npm") && lower.contains(" dev") { return "npm dev" }
        return nil
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] / 2 + sorted[middle] / 2
        }
        return sorted[middle]
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}
