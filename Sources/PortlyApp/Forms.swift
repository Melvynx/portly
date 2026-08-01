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

    @State private var hoveredSymbol: String?

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 5), count: 9)
    private let colorNames = ["Blue", "Green", "Orange", "Pink", "Purple", "Cyan", "Yellow", "Gray"]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: color).opacity(0.16))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(hex: color).opacity(0.28))
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color(hex: color))
            }
            .frame(width: 54, height: 54)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Project icon preview")

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Color")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 7) {
                        ForEach(Array(Supervisor.palette.enumerated()), id: \.element) { index, hex in
                            Button {
                                color = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 18, height: 18)
                                    .padding(4)
                                    .background {
                                        Circle()
                                            .strokeBorder(
                                                color == hex ? Color.primary.opacity(0.7) : Color.clear,
                                                lineWidth: 2
                                            )
                                    }
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(colorNames[index])
                            .accessibilityValue(color == hex ? "Selected" : "")
                            .help(colorNames[index])
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Symbol")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 5) {
                        ForEach(Project.icons, id: \.self) { symbol in
                            Button {
                                icon = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 14, weight: icon == symbol ? .medium : .regular))
                                    .foregroundStyle(icon == symbol ? Color(hex: color) : Color.secondary)
                                    .frame(width: 30, height: 28)
                                    .background {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(symbolBackground(symbol))
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(
                                                icon == symbol ? Color(hex: color).opacity(0.32) : Color.clear
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                            .accessibilityValue(icon == symbol ? "Selected" : "")
                            .help(symbol)
                            .onHover { hovering in
                                hoveredSymbol = hovering ? symbol : nil
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func symbolBackground(_ symbol: String) -> Color {
        if icon == symbol { return Color(hex: color).opacity(0.14) }
        if hoveredSymbol == symbol { return Color.primary.opacity(0.07) }
        return .clear
    }
}

/// Add or edit a server.
struct ServerForm: View {
    private enum SetupMode {
        case automatic
        case manual
    }

    let server: ServerConfig?
    let projectName: String
    let projectRoot: String
    let onSave: (ServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var supervisor: Supervisor
    @State private var name = ""
    @State private var command = ""
    @State private var portText = ""
    @State private var directory = ""
    @State private var healthURL = ""
    @State private var autoRestart = true
    @State private var envText = ""
    @State private var suggestions: [CommandDetector.Suggestion] = []
    @State private var setupMode: SetupMode = .automatic
    @State private var isDetecting = true
    @State private var selectedSuggestionID: String?
    @State private var advancedExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if showsAutomaticSetup {
                    automaticSetup
                } else {
                    manualSetup
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if server == nil {
                    if showsAutomaticSetup {
                        Button("Set up manually") { setupMode = .manual }
                    } else if !suggestions.isEmpty {
                        Button("Use detected command") { setupMode = .automatic }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(server == nil ? "Add Server" : "Save") {
                    onSave(build())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 520)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var automaticSetup: some View {
        if isDetecting {
            Section("Finding commands") {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking through \(projectName)…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        } else if suggestions.isEmpty {
            Section("No commands detected") {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Portly could not find a development command")
                        Text("You can still add one with the manual setup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        } else {
            Section {
                ForEach(suggestions) { suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        isSelected: selectedSuggestionID == suggestion.id
                    ) {
                        apply(suggestion)
                    }
                }
            } header: {
                Text("Detected commands")
            } footer: {
                Text("Choose what Portly should run for \(projectName). You can edit every setting later.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var manualSetup: some View {
        Section {
            TextField("Name", text: $name)
                .help("How the server shows up in the sidebar, for example \"web\" or \"api\"")
            TextField("Command", text: $command)
                .font(.system(size: 12, design: .monospaced))
                .help("Runs through a login shell, so pnpm, nvm and mise all work")
            TextField("Port", text: $portText)
                .multilineTextAlignment(.trailing)
        } header: {
            Text(server == nil ? "Manual setup" : projectName)
        } footer: {
            Text(portHelpText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("Behavior") {
            Toggle("Restart automatically when it crashes", isOn: $autoRestart)
        }

        Section {
            DisclosureGroup("Advanced options", isExpanded: $advancedExpanded) {
                TextField("Directory", text: $directory)
                    .font(.system(size: 12, design: .monospaced))
                    .help("Relative to the project folder, or an absolute path. Empty means the project folder.")
                TextField("Health URL", text: $healthURL)
                    .help("A path like /api/health, or a full URL. Empty means a plain TCP check.")
                TextField("Environment", text: $envText, axis: .vertical)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2...4)
                    .help("One KEY=VALUE per line")
            }
        }
    }

    private var showsAutomaticSetup: Bool {
        server == nil && setupMode == .automatic
    }

    private var canSave: Bool {
        let hasRequiredFields = !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
        if showsAutomaticSetup { return selectedSuggestionID != nil && hasRequiredFields }
        return hasRequiredFields
    }

    private var portHelpText: String {
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)) {
            return "Portly will open http://localhost:\(port) and use this port for health checks."
        }
        return "Leave the port empty only when this command does not start a local server."
    }

    private func apply(_ suggestion: CommandDetector.Suggestion) {
        selectedSuggestionID = suggestion.id
        name = suggestion.name
        command = suggestion.command
        portText = suggestion.port.map(String.init) ?? ""
        directory = suggestion.directory ?? ""
    }

    private func load() {
        // Detection is for new servers; editing an existing one should not
        // offer to overwrite the command you already tuned.
        if server == nil {
            let root = projectRoot
            let reservedPorts = Set(supervisor.projects.flatMap(\.servers).compactMap(\.port))
            portText = String(supervisor.nextAvailablePort(startingAt: 3000))
            DispatchQueue.global(qos: .userInitiated).async {
                let found = CommandDetector.suggestions(inProjectRoot: root, reservedPorts: reservedPorts)
                DispatchQueue.main.async {
                    suggestions = found
                    isDetecting = false
                }
            }
        } else {
            setupMode = .manual
            isDetecting = false
        }
        guard let server else { return }
        name = server.name
        command = server.command
        portText = server.port.map(String.init) ?? ""
        directory = server.directory ?? ""
        healthURL = server.healthURL ?? ""
        autoRestart = server.autoRestart
        envText = server.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        advancedExpanded = !(directory.isEmpty && healthURL.isEmpty && envText.isEmpty)
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
    let isSelected: Bool
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.command)
                        .font(.system(size: 12, design: .monospaced))
                    HStack(spacing: 6) {
                        Text(suggestion.source)
                        if let port = suggestion.port {
                            Text("Port \(String(port))")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
