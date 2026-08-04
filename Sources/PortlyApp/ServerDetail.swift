import AppKit
import PortlyCore
import SwiftUI

/// The terminal plus everything you need to act on one server.
struct ServerDetail: View {
    @ObservedObject var runtime: ServerRuntime
    let onEdit: (() -> Void)?

    @EnvironmentObject private var supervisor: Supervisor
    @State private var conflict: PortOccupant?
    @State private var showsResources = false
    @State private var conflictActionError: String?

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            Divider()
            // The conflict is found by an async lsof, so it lands well after the
            // pane is drawn. Sliding it down from the top edge makes it read as
            // a banner arriving rather than the terminal jumping.
            if let conflict, !conflict.ownedByPortly {
                VStack(spacing: 0) {
                    conflictBanner(conflict)
                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if runtime.state == .stopped {
                stoppedState
                    .transition(.opacity)
            } else {
                TerminalPane(runtime: runtime)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(Motion.banner, value: conflict?.pid)
        .animation(Motion.paneSwap, value: runtime.state == .stopped)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if runtime.isRunning {
                        runtime.stop()
                    } else {
                        runtime.start()
                    }
                } label: {
                    Label(
                        runtime.isRunning ? "Stop" : runtime.state == .failed ? "Retry" : "Start",
                        systemImage: runtime.isRunning ? "stop.fill" : runtime.state == .failed ? "arrow.clockwise" : "play.fill"
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .animation(Motion.state, value: runtime.isRunning)
                .help(
                    runtime.isRunning
                        ? "Stop the server"
                        : runtime.state == .failed
                            ? "Reset retries and start the server"
                            : "Start the server"
                )

                if runtime.isRunning {
                    Button { runtime.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .help("Restart the server")
                }

                if let url = runtime.url {
                    Button {
                        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .help("Open \(url)")
                }

                if runtime.state != .stopped {
                    Button { runtime.clearTerminal() } label: { Label("Clear", systemImage: "eraser") }
                        .help("Clear the terminal")
                }

                if let onEdit {
                    Button(action: onEdit) { Label("Edit", systemImage: "slider.horizontal.3") }
                        .help("Edit this server")
                }
            }
        }
        .navigationTitle(runtime.config.name)
        .navigationSubtitle(runtime.projectName)
        .onAppear(perform: refreshConflict)
        .onChange(of: runtime.state) { refreshConflict() }
        .alert("Unable to stop port owner", isPresented: Binding(
            get: { conflictActionError != nil },
            set: { if !$0 { conflictActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conflictActionError ?? "The port owner could not be stopped.")
        }
    }

    private var stoppedState: some View {
        VStack(spacing: 12) {
            Image(systemName: stoppedIcon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(runtime.temporaryJobStatus?.state == .succeeded ? Color.green : Color.secondary)

            VStack(spacing: 4) {
                Text(stoppedTitle)
                    .font(PortlyTypography.title)
                Text(stoppedMessage)
                    .font(PortlyTypography.body)
                    .foregroundStyle(.secondary)
            }

            Button(runtime.isTemporaryJob ? "Run Again" : "Start", systemImage: "play.fill") {
                runtime.start()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stoppedIcon: String {
        switch runtime.temporaryJobStatus?.state {
        case .succeeded: return "checkmark.circle"
        case .failed, .timedOut: return "xmark.circle"
        default: return "terminal"
        }
    }

    private var stoppedTitle: String {
        guard let job = runtime.temporaryJobStatus else { return "Server is stopped" }
        switch job.state {
        case .succeeded: return "Job succeeded"
        case .failed: return "Job failed"
        case .timedOut: return "Job timed out"
        case .stopped: return "Job stopped"
        case .running: return "Job is running"
        }
    }

    private var stoppedMessage: String {
        guard let job = runtime.temporaryJobStatus else {
            return "Start \(runtime.config.name) to see its live terminal output."
        }
        let duration = job.elapsedSeconds.map { String(format: "%.1f seconds", $0) } ?? "an unknown duration"
        let exitCode = job.exitCode.map { " with exit code \($0)" } ?? ""
        return "Finished in \(duration)\(exitCode). Its captured output remains available here for one hour."
    }

    // MARK: - Info bar

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                StatusBadge(state: runtime.state)

                if let pid = runtime.pid {
                    fact("PID \(pid)", systemImage: "number")
                }
                if let port = runtime.config.port {
                    fact("Port \(port)", systemImage: "network")
                }
                if let startedAt = runtime.startedAt, runtime.isRunning {
                    fact("Up \(startedAt.compactUptime)", systemImage: "clock")
                }
                if let job = runtime.temporaryJobStatus {
                    fact(jobFact(job), systemImage: job.state == .running ? "timer" : "checkmark.circle")
                }
                if runtime.restartCount > 0 {
                    fact(
                        "\(runtime.restartCount)/\(supervisor.settings.maxRestartAttempts) restarts",
                        systemImage: "arrow.clockwise"
                    )
                }

                Spacer()

                if let error = runtime.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(error)
                }

                if runtime.processMetrics != nil {
                    Button {
                        showsResources.toggle()
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                            .foregroundStyle(showsResources ? Color.accentColor : Color.secondary)
                            .frame(width: 24, height: 24)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(showsResources ? Color.accentColor.opacity(0.12) : .clear)
                            }
                    }
                    .buttonStyle(.borderless)
                    .help(showsResources ? "Hide resource use" : "Show resource use")
                    .accessibilityLabel(showsResources ? "Hide resource use" : "Show resource use")
                }
            }

            if let metrics = runtime.processMetrics, showsResources {
                HStack(spacing: 18) {
                    compactResource(
                        value: metrics.cpuPercent.formatted(.number.precision(.fractionLength(1))) + "%",
                        systemImage: "cpu",
                        color: metrics.cpuPressure.color,
                        label: "CPU",
                        help: "Total CPU used by this server and its child processes"
                    )
                    compactResource(
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(metrics.memoryBytes),
                            countStyle: .memory
                        ),
                        systemImage: "memorychip",
                        color: metrics.memoryPressure.color,
                        label: "Memory",
                        help: "Total memory owned by this server and its child processes"
                    )
                    compactResource(
                        value: String(metrics.processCount),
                        systemImage: "square.stack.3d.up",
                        color: .blue,
                        label: "Processes",
                        help: "Processes Portly groups together for this server"
                    )

                    Spacer()

                    Button {
                        AppSelection.shared.pending = .resources
                    } label: {
                        Label("Details", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Open the resource dashboard")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func fact(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(PortlyTypography.metadata)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func jobFact(_ job: TemporaryJobStatus) -> String {
        switch job.state {
        case .running: return "Timeout \(TemporaryTimeout.display(job.timeoutSeconds))"
        case .succeeded: return "Succeeded"
        case .failed: return job.exitCode.map { "Failed · exit \($0)" } ?? "Failed"
        case .timedOut: return "Timed out · \(TemporaryTimeout.display(job.timeoutSeconds))"
        case .stopped: return "Stopped"
        }
    }

    private func compactResource(
        value: String,
        systemImage: String,
        color: Color,
        label: String,
        help: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
            Text(value)
                .font(PortlyTypography.metric)
                .monospacedDigit()
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityHint(help)
    }

    // MARK: - Port conflict

    private func conflictBanner(_ occupant: PortOccupant) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(occupant.dockerContainerID == nil ? "Running outside Portly" : "Docker container outside Portly")
                    .font(.system(size: 12, weight: .medium))
                Text(conflictDescription(occupant))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(occupant.dockerContainerID == nil ? "Stop process" : "Stop container") {
                stopConflictOwner(occupant)
            }
            .controlSize(.small)
            Button("Move to Portly") {
                if runtime.takeOverPort() { conflict = nil }
            }
            .controlSize(.small)
            .help("Stop the current owner safely, then start \(runtime.projectName) / \(runtime.config.name) under Portly")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private func conflictDescription(_ occupant: PortOccupant) -> String {
        if let name = occupant.dockerContainerName {
            let service = [occupant.dockerComposeProject, occupant.dockerComposeService]
                .compactMap { $0 }
                .joined(separator: " / ")
            let identity = service.isEmpty ? name : service
            return "\(identity) publishes port \(occupant.port) through Docker Desktop (backend pid \(occupant.pid))."
        }
        return "\(occupant.command) (pid \(occupant.pid)) is using port \(occupant.port)."
    }

    private func stopConflictOwner(_ occupant: PortOccupant) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PortInspector.stopOccupant(of: occupant.port, expectedPID: occupant.pid)
            }.value
            switch result {
            case .success:
                try? await Task.sleep(for: .milliseconds(500))
                refreshConflict()
            case .failure(let error):
                conflictActionError = error.localizedDescription
            }
        }
    }

    /// Only interesting when our own server is not the listener.
    private func refreshConflict() {
        guard let port = runtime.config.port, !runtime.isRunning else {
            conflict = nil
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = supervisor.occupant(of: port)
            DispatchQueue.main.async { conflict = found }
        }
    }
}
