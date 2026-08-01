import AppKit
import PortlyCore
import SwiftUI

/// The menu bar popover: everything you need without opening the window, and a
/// way in when you do.
struct MenuBarContent: View {
    @EnvironmentObject private var supervisor: Supervisor
    @Environment(\.openWindow) private var openWindow
    @State private var listHeight: CGFloat = 0

    private static let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if supervisor.projects.isEmpty {
                emptyState
            } else {
                // A menu bar window sizes itself to the content's fitting size, and
                // a ScrollView reports none, so it would collapse to nothing. Measure
                // the list and give the scroller an explicit height.
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(supervisor.projects) { project in
                            projectSection(project)
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ListHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                }
                .frame(height: min(max(listHeight, estimatedListHeight), Self.maxListHeight))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            }

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear {
            WindowOpener.opener = { openWindow(id: WindowOpener.mainWindowID) }
        }
    }

    /// Fallback used before the list has been measured, so the popover never
    /// opens empty: roughly one 22pt row per project header and per server.
    private var estimatedListHeight: CGFloat {
        let rows = supervisor.projects.reduce(0) { $0 + 1 + $1.servers.count }
        return CGFloat(rows) * 22 + 12
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Portly")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.state, value: supervisor.runningCount)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let running = supervisor.runningCount
        let total = supervisor.projects.reduce(0) { $0 + $1.servers.count }
        return "\(running)/\(total) running"
    }

    private func projectSection(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: project.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: project.color))
                    .frame(width: 13)
                Text(project.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    supervisor.startProject(project.id)
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Start every server in \(project.name)")

                Button {
                    supervisor.stopProject(project.id)
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Stop every server in \(project.name)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(project.servers) { server in
                if let runtime = supervisor.runtime(for: server.id) {
                    MenuBarServerRow(runtime: runtime)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No projects yet")
                .font(.system(size: 12, weight: .medium))
            Text("Open the window to add a project and its servers.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Portly") {
                WindowOpener.openMainWindow()
            }
            .buttonStyle(.borderless)

            Button("Ports") {
                AppSelection.shared.pending = .ports
                WindowOpener.openMainWindow()
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Stop All") {
                supervisor.stopAll()
            }
            .buttonStyle(.borderless)
            .disabled(supervisor.runningCount == 0)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct MenuBarServerRow: View {
    @ObservedObject var runtime: ServerRuntime
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: runtime.state)

            Text(runtime.config.name)
                .font(.system(size: 12))
                .lineLimit(1)

            if let port = runtime.config.port {
                Text(":\(String(port))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            StartStopButton(runtime: runtime, symbolSize: 9)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.secondary.opacity(0.12) : Color.clear)
                .padding(.horizontal, 6)
        )
        .animation(Motion.hover, value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            AppSelection.shared.pending = .server(runtime.id)
            WindowOpener.openMainWindow()
        }
    }
}

/// Carries the measured height of the project list out of the ScrollView.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Lets the menu bar ask the main window to focus a specific server.
final class AppSelection: ObservableObject {
    static let shared = AppSelection()
    @Published var pending: MainView.Selection?
    private init() {}
}
