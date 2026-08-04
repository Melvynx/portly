import Foundation

/// Turns noisy two-second memory samples into a deliberate restart decision.
/// Three consecutive over-limit samples avoid reacting to a single allocation
/// spike. After a restart, the counter starts fresh for the new process tree.
struct MemoryLimitGuard {
    static let requiredConsecutiveSamples = 3

    private var overLimitSamples: [String: Int] = [:]

    mutating func shouldRestart(
        projectID: String,
        footprintBytes: UInt64,
        limitBytes: UInt64?,
        hasRunningServers: Bool
    ) -> Bool {
        guard let limitBytes, hasRunningServers else {
            overLimitSamples[projectID] = 0
            return false
        }
        guard footprintBytes > limitBytes else {
            overLimitSamples[projectID] = 0
            return false
        }

        let count = (overLimitSamples[projectID] ?? 0) + 1
        overLimitSamples[projectID] = count
        guard count >= Self.requiredConsecutiveSamples else { return false }

        overLimitSamples[projectID] = 0
        return true
    }

    mutating func removeProjects(except activeProjectIDs: Set<String>) {
        overLimitSamples = overLimitSamples.filter { activeProjectIDs.contains($0.key) }
    }

    mutating func reset(projectID: String) {
        overLimitSamples.removeValue(forKey: projectID)
    }

    mutating func resetAll() {
        overLimitSamples.removeAll()
    }
}

struct MemoryLimitRestartEvent: Equatable {
    let projectID: String
    let timestamp: Date
    let footprintBytes: UInt64
    let limitBytes: UInt64
    let restartedServerIDs: [String]
}
