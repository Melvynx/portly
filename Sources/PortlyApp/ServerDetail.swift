import AppKit
import PortlyCore
import SwiftUI

/// The terminal plus everything you need to act on one server.
struct ServerDetail: View {
    @ObservedObject var runtime: ServerRuntime
    let onEdit: () -> Void

    @EnvironmentObject private var supervisor: Supervisor
    @State private var conflict: PortOccupant?

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            Divider()
            if let conflict, !conflict.ownedByPortly {
                conflictBanner(conflict)
                Divider()
            }
            TerminalPane(runtime: runtime)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                if runtime.isRunning {
                    Button { runtime.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop the server")
                    Button { runtime.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .help("Restart the server")
                } else {
                    Button { runtime.start() } label: { Label("Start", systemImage: "play.fill") }
                        .help("Start the server")
                }

                if let url = runtime.url {
                    Button {
                        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .help("Open \(url)")
                }

                Button { runtime.clearTerminal() } label: { Label("Clear", systemImage: "eraser") }
                    .help("Clear the terminal")

                Button(action: onEdit) { Label("Edit", systemImage: "slider.horizontal.3") }
                    .help("Edit this server")
            }
        }
        .navigationTitle(runtime.config.name)
        .navigationSubtitle(runtime.projectName)
        .onAppear(perform: refreshConflict)
        .onChange(of: runtime.state) { refreshConflict() }
    }

    // MARK: - Info bar

    private var infoBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                StatusDot(state: runtime.state, size: 9)
                Text(runtime.state.label)
                    .font(.system(size: 12, weight: .medium))
            }

            if let pid = runtime.pid {
                metric("PID", String(pid))
            }
            if let port = runtime.config.port {
                metric("Port", String(port))
            }
            if let startedAt = runtime.startedAt, runtime.isRunning {
                metric("Uptime", startedAt.compactUptime)
            }
            if runtime.restartCount > 0 {
                metric("Restarts", "\(runtime.restartCount)/\(supervisor.settings.maxRestartAttempts)")
            }

            Spacer()

            if let error = runtime.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
        }
    }

    // MARK: - Port conflict

    private func conflictBanner(_ occupant: PortOccupant) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Running outside Portly")
                    .font(.system(size: 12, weight: .medium))
                Text("\(occupant.command) (pid \(String(occupant.pid))) is using port \(String(occupant.port)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop process") {
                PortInspector.kill(pid: occupant.pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: refreshConflict)
            }
            .controlSize(.small)
            Button("Move to Portly") {
                if runtime.takeOverPort() { conflict = nil }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
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
