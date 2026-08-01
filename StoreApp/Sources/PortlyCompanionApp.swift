import SwiftUI

@main
struct PortlyCompanionApp: App {
    @StateObject private var model = CompanionModel()

    var body: some Scene {
        WindowGroup {
            CompanionView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 860, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case unavailable(String)
    }

    @Published private(set) var projects: [CompanionProject] = []
    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published private(set) var activeAction: String?

    func refresh() async {
        do {
            let status = try await PortlyServiceClient.status()
            projects = status.projects
            connectionState = .connected
        } catch {
            projects = []
            connectionState = .unavailable(error.localizedDescription)
        }
    }

    func perform(_ action: String, on server: CompanionServer) async {
        activeAction = server.id
        defer { activeAction = nil }
        do {
            try await PortlyServiceClient.perform(action, serverID: server.id)
            try? await Task.sleep(for: .milliseconds(350))
            await refresh()
        } catch {
            connectionState = .unavailable(error.localizedDescription)
        }
    }
}

private struct CompanionView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.connectionState {
                case .connecting:
                    ProgressView("Connecting to Portly…")
                case .unavailable(let message):
                    unavailableView(message)
                case .connected:
                    projectList
                }
            }
            .navigationTitle("Portly Companion")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await model.refresh()
            }
        }
    }

    private var projectList: some View {
        List {
            Section {
                Label("Connected securely on this Mac", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("The companion controls your existing Portly service over 127.0.0.1. It never launches shell commands or reads project files itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.projects) { project in
                Section(project.name) {
                    if project.servers.isEmpty {
                        Text("No servers configured")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(project.servers) { server in
                        CompanionServerRow(
                            server: server,
                            isBusy: model.activeAction == server.id,
                            perform: { action in
                                Task { await model.perform(action, on: server) }
                            }
                        )
                    }
                }
            }
        }
        .overlay {
            if model.projects.isEmpty {
                ContentUnavailableView(
                    "No Portly projects",
                    systemImage: "shippingbox",
                    description: Text("Add a project in the full Portly app, then refresh this companion.")
                )
            }
        }
    }

    private func unavailableView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Portly service is not running", systemImage: "bolt.slash")
        } description: {
            Text("Portly Companion controls an existing Portly installation on this Mac. \(message)")
        } actions: {
            HStack {
                Button("Try Again") {
                    Task { await model.refresh() }
                }
                Link("Get Portly", destination: URL(string: "https://portly.melvynx.dev")!)
            }
        }
    }
}

private struct CompanionServerRow: View {
    let server: CompanionServer
    let isBusy: Bool
    let perform: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(server.state.capitalized)
                    if let port = server.port {
                        Text("localhost:\(port)")
                    }
                    if let pid = server.pid {
                        Text("pid \(pid)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if server.isRunning {
                Button("Restart") { perform("/restart") }
                Button("Stop") { perform("/stop") }
            } else {
                Button("Start") { perform("/start") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 5)
    }

    private var statusColor: Color {
        if server.healthy { return .green }
        if server.isRunning { return .orange }
        return .secondary
    }
}
