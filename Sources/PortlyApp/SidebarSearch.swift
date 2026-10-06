import Foundation
import PortlyCore
import SwiftUI

/// Substring filter for the main-window sidebar. Matching is case-insensitive
/// and ignores surrounding whitespace, same as the Ports screen.
enum SidebarSearch {
    static func isActive(_ query: String) -> Bool {
        !normalized(query).isEmpty
    }

    static func filterProjects(_ projects: [Project], query: String) -> [Project] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return projects }

        return projects.compactMap { project in
            if projectMatches(project, needle: needle) {
                return project
            }

            let servers = project.servers.filter { serverMatches($0, needle: needle) }
            guard !servers.isEmpty else { return nil }

            // Display copy only. Never write this value back to the store.
            var filtered = project
            filtered.servers = servers
            return filtered
        }
    }

    static func matchesServer(
        _ server: ServerConfig,
        query: String,
        project: Project? = nil
    ) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        if let project, projectMatches(project, needle: needle) {
            return true
        }
        return serverMatches(server, needle: needle)
    }

    static func firstMatch(
        temporaryServers: [ServerConfig],
        projects: [Project],
        query: String
    ) -> SidebarSearchMatch? {
        guard isActive(query) else { return nil }
        let temps = temporaryServers.filter { matchesServer($0, query: query) }
        if let server = temps.first {
            return .server(server.id)
        }

        let filtered = filterProjects(projects, query: query)
        guard let project = filtered.first else { return nil }
        if let server = project.servers.first {
            return .server(server.id)
        }
        return .project(project.id)
    }

    private static func projectMatches(_ project: Project, needle: String) -> Bool {
        contains(project.name, needle)
            || contains((project.root as NSString).lastPathComponent, needle)
    }

    private static func serverMatches(_ server: ServerConfig, needle: String) -> Bool {
        if contains(server.name, needle) || contains(server.command, needle) {
            return true
        }
        guard let port = server.port else { return false }
        return String(port).contains(needle) || contains("localhost:\(port)", needle)
    }

    private static func contains(_ value: String, _ needle: String) -> Bool {
        value.lowercased().contains(needle)
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum SidebarSearchMatch: Equatable {
    case project(String)
    case server(String)
}

struct SidebarSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search projects", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
                .accessibilityLabel("Search projects and servers")
                .accessibilityHint(
                    "Filters the sidebar by project, server, command, or port. Press Return to select the first match."
                )

            if SidebarSearch.isActive(text) {
                Button {
                    text = ""
                    focused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .background {
            Button("Search") { focused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .help("Filter the sidebar by project, server, or port")
    }
}
