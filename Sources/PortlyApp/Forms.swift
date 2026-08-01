import AppKit
import PortlyCore
import SwiftUI

/// Add or edit a project. Standard grouped form, standard sheet buttons.
struct ProjectForm: View {
    let project: Project?
    let onSave: (String, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var root: String = ""
    @State private var icon: String = Project.defaultIcon
    @State private var color: String = Supervisor.palette[0]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    HStack {
                        TextField("Folder", text: $root)
                            .font(.system(size: 12, design: .monospaced))
                        Button("Choose…", action: chooseFolder)
                    }
                }

                Section("Appearance") {
                    IconColorPicker(icon: $icon, color: $color)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(project == nil ? "Add Project" : "Save") {
                    onSave(name.trimmingCharacters(in: .whitespaces), root, icon, color)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || root.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 480)
        .onAppear {
            guard let project else { return }
            name = project.name
            root = project.root
            icon = project.icon
            color = project.color
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            root = url.path
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
}

/// A grid of colors and a grid of symbols, drawn as they will actually look in
/// the sidebar. A hex string in a popup told you nothing.
private struct IconColorPicker: View {
    @Binding var icon: String
    @Binding var color: String

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 6), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Supervisor.palette, id: \.self) { hex in
                    Button {
                        color = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 20, height: 20)
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.primary.opacity(color == hex ? 0.9 : 0), lineWidth: 2)
                                    .padding(-3)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Project.icons, id: \.self) { symbol in
                    Button {
                        icon = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(icon == symbol ? Color(hex: color) : Color.secondary)
                            .frame(width: 28, height: 26)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(icon == symbol ? Color(hex: color).opacity(0.18) : Color.clear)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Add or edit a server.
struct ServerForm: View {
    let server: ServerConfig?
    let projectName: String
    let projectRoot: String
    let onSave: (ServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var portText = ""
    @State private var directory = ""
    @State private var healthURL = ""
    @State private var autoRestart = true
    @State private var envText = ""
    @State private var suggestions: [CommandDetector.Suggestion] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            SuggestionRow(suggestion: suggestion) { apply(suggestion) }
                        }
                    } header: {
                        Text("Detected in \(projectName)")
                    } footer: {
                        Text("Click one to fill the fields below. You can still edit anything afterwards.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Name", text: $name)
                        .help("How the server shows up in the sidebar, for example \"web\" or \"api\"")
                    TextField("Command", text: $command)
                        .font(.system(size: 12, design: .monospaced))
                        .help("Runs through a login shell, so pnpm, nvm and mise all work")
                    TextField("Port", text: $portText)
                        .frame(width: 120)
                } header: {
                    Text(projectName)
                } footer: {
                    Text("The port drives the health check. Leave it empty for a server that does not listen.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Optional") {
                    TextField("Directory", text: $directory)
                        .font(.system(size: 12, design: .monospaced))
                        .help("Relative to the project folder, or an absolute path. Empty means the project folder.")
                    TextField("Health URL", text: $healthURL)
                        .help("A path like /api/health, or a full URL. Empty means a plain TCP check.")
                    TextField("Environment", text: $envText, axis: .vertical)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(3...6)
                        .help("One KEY=VALUE per line")
                    Toggle("Restart automatically when it crashes", isOn: $autoRestart)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(server == nil ? "Add Server" : "Save") {
                    onSave(build())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func apply(_ suggestion: CommandDetector.Suggestion) {
        // Only fills what you have not typed yourself, except the command,
        // which is the whole point of clicking the row.
        command = suggestion.command
        if name.isEmpty { name = suggestion.name }
        if portText.isEmpty, let port = suggestion.port { portText = String(port) }
        if directory.isEmpty, let dir = suggestion.directory { directory = dir }
    }

    private func load() {
        // Detection is for new servers; editing an existing one should not
        // offer to overwrite the command you already tuned.
        if server == nil {
            let root = projectRoot
            DispatchQueue.global(qos: .userInitiated).async {
                let found = CommandDetector.suggestions(inProjectRoot: root)
                DispatchQueue.main.async { suggestions = found }
            }
        }
        guard let server else { return }
        name = server.name
        command = server.command
        portText = server.port.map(String.init) ?? ""
        directory = server.directory ?? ""
        healthURL = server.healthURL ?? ""
        autoRestart = server.autoRestart
        envText = server.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private func build() -> ServerConfig {
        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            env[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1])
        }
        return ServerConfig(
            id: server?.id ?? ServerConfig.newID(),
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            port: Int(portText.trimmingCharacters(in: .whitespaces)),
            directory: directory.isEmpty ? nil : directory,
            env: env,
            healthURL: healthURL.isEmpty ? nil : healthURL,
            healthStatus: server?.healthStatus,
            autoRestart: autoRestart
        )
    }
}

private struct SuggestionRow: View {
    let suggestion: CommandDetector.Suggestion
    let onPick: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.command)
                        .font(.system(size: 12, design: .monospaced))
                    HStack(spacing: 6) {
                        Text(suggestion.source)
                        if let port = suggestion.port {
                            Text("port \(String(port))")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Use")
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
