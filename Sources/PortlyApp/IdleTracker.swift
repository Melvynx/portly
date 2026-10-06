import Foundation

/// Decides when a supervised server has been quiet long enough to stop.
/// Output, terminal input, and CPU at or above `busyCPUPercent` count as
/// activity. Output that lands right after a Portly health probe does not:
/// servers that log every request (Next, `python -m http.server`) would
/// otherwise keep themselves alive by answering Portly.
struct IdleTracker {
    static let busyCPUPercent = 5.0
    static let maximumProbeEchoWindow: TimeInterval = 2

    private(set) var lastActivityAt: Date?
    private var lastProbeAt: Date?
    private var probeEchoWindow: TimeInterval = 0

    mutating func reset(at date: Date) {
        lastActivityAt = date
        lastProbeAt = nil
    }

    mutating func clear() {
        lastActivityAt = nil
        lastProbeAt = nil
    }

    /// The echo window stays a fraction of the probe interval so fast startup
    /// probing cannot hide all output.
    mutating func recordProbe(at date: Date, interval: TimeInterval) {
        lastProbeAt = date
        probeEchoWindow = min(Self.maximumProbeEchoWindow, interval / 4)
    }

    mutating func recordOutput(at date: Date) {
        if let lastProbeAt {
            let sinceProbe = date.timeIntervalSince(lastProbeAt)
            if sinceProbe >= 0, sinceProbe < probeEchoWindow { return }
        }
        lastActivityAt = date
    }

    mutating func recordInput(at date: Date) {
        lastActivityAt = date
    }

    mutating func recordCPU(_ percent: Double, at date: Date) {
        guard percent >= Self.busyCPUPercent else { return }
        lastActivityAt = date
    }

    func isIdle(timeoutSeconds: Int, now: Date) -> Bool {
        guard let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) >= TimeInterval(timeoutSeconds)
    }
}
