import AppKit
import PortlyCore
import SwiftUI

/// Add or edit a project. Standard grouped form, standard sheet buttons.
struct ProjectForm: View {
    let project: Project?
    /// Colors already spoken for, so the picker can warn before two projects end up
    /// with the same line in the resource charts.
    var takenColors: [String] = []
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
                    IconColorPicker(icon: $icon, color: $color, takenColors: takenColors)
                }

            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(project == nil ? "Add Project" : "Save") {
                    onSave(
                        name.trimmingCharacters(in: .whitespaces),
                        root,
                        icon,
                        color
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty
                        || root.isEmpty
                )
            }
            .padding(14)
        }
        .frame(width: 480)
        .onAppear {
            guard let project else {
                color = Supervisor.nextColor(excluding: takenColors)
                return
            }
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
    var takenColors: [String] = []

    @State private var hoveredSymbol: String?

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 5), count: 9)

    private var taken: Set<String> {
        Set(takenColors.map { $0.uppercased() }).subtracting([color.uppercased()])
    }

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
                            let name = Supervisor.paletteNames[index]
                            let isTaken = taken.contains(hex.uppercased())
                            Button {
                                color = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 18, height: 18)
                                    // A taken color stays selectable, it just stops
                                    // looking like a fresh one.
                                    .opacity(isTaken ? 0.3 : 1)
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
                            .accessibilityLabel(name)
                            .accessibilityValue(
                                [color == hex ? "Selected" : nil, isTaken ? "Already used" : nil]
                                    .compactMap { $0 }
                                    .joined(separator: ", ")
                            )
                            .help(isTaken ? "\(name), already used by another project" : name)
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
    let projectID: String
    let projectName: String
    let projectRoot: String
    let onSave: (ServerConfig, MemoryLimitMode, UInt64?) -> Void

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
    @State private var memoryLimitMode: MemoryLimitMode = .inherit
    @State private var memoryLimit = "5GB"
    @State private var showMemoryLimitError = false
    @FocusState private var memoryLimitFocused: Bool

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
                Button(server == nil ? "Add Server" : "Save", action: save)
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

        Section("Project memory guard") {
            Picker("Policy", selection: $memoryLimitMode) {
                Text("Use global default").tag(MemoryLimitMode.inherit)
                Text("Turn off for this project").tag(MemoryLimitMode.disabled)
                Text("Set a custom limit").tag(MemoryLimitMode.custom)
            }

            if memoryLimitMode == .custom {
                TextField("Limit", text: $memoryLimit)
                    .focused($memoryLimitFocused)
                    .help("For example 5GB or 5Go")
                    .accessibilityHint(memoryLimitMessage)

                Text(memoryLimitMessage)
                    .font(.caption)
                    .foregroundStyle(showMemoryLimitError && parsedMemoryLimit == nil ? Color.red : Color.secondary)
            } else if memoryLimitMode == .inherit {
                Text(globalMemoryLimitMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("This policy applies to the total footprint of every running server in \(projectName).")
                .font(.caption)
                .foregroundStyle(.secondary)
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

        if let project = supervisor.projects.first(where: { $0.id == projectID }) {
            memoryLimitMode = project.memoryLimitMode
            let bytes = project.memoryLimitBytes ?? supervisor.settings.globalMemoryLimitBytes
            if let bytes {
                memoryLimit = MemorySize.display(bytes).replacingOccurrences(of: " ", with: "")
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
        advancedExpanded = !(directory.isEmpty && healthURL.isEmpty && envText.isEmpty)
    }

    private var parsedMemoryLimit: UInt64? {
        MemorySize.parse(memoryLimit)
    }

    private var memoryLimitMessage: String {
        if showMemoryLimitError, parsedMemoryLimit == nil {
            return "Enter a size of at least 64 MB, for example 5GB."
        }
        return "Examples: 512MB, 5GB, or 5Go. Minimum: 64 MB."
    }

    private var globalMemoryLimitMessage: String {
        supervisor.settings.globalMemoryLimitBytes.map {
            "The current global default is \(MemorySize.display($0))."
        } ?? "The global default is off, so automatic memory restarts are currently disabled."
    }

    private func save() {
        if memoryLimitMode == .custom, parsedMemoryLimit == nil {
            showMemoryLimitError = true
            memoryLimitFocused = true
            return
        }
        onSave(
            build(),
            memoryLimitMode,
            memoryLimitMode == .custom ? parsedMemoryLimit : nil
        )
        dismiss()
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

/// Launches an ephemeral process without adding permanent project or server
/// configuration. It intentionally asks for only the fields useful to a small
/// preview or one-off task.
struct TemporaryProcessForm: View {
    let onRun: (String, String, String, Int?, String?, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = "Temporary process"
    @State private var command = ""
    @State private var directory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var portText = ""
    @State private var healthURL = ""
    @State private var timeoutText = "30m"

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Label {
                        Text("Temporary jobs run in the background, stop their full process group at the timeout, and keep their result for one hour.")
                    } icon: {
                        Image(systemName: "clock.badge")
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(PortlyTypography.body)

                    Text("For long-lived or reusable work, create a project instead.")
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                }

                Section("Process") {
                    TextField("Name", text: $name)
                    TextField("Command", text: $command, axis: .vertical)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2...5)

                    HStack {
                        TextField("Working directory", text: $directory)
                            .font(.system(size: 12, design: .monospaced))
                        Button("Choose…", action: chooseDirectory)
                    }
                }

                Section("Monitoring") {
                    TextField("Timeout (for example 30s, 10m, 2h)", text: $timeoutText)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder)
                    TextField("Health path or URL", text: $healthURL)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run Temporary") {
                    if let timeoutSeconds = TemporaryTimeout.parse(timeoutText) {
                        onRun(
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            command.trimmingCharacters(in: .whitespacesAndNewlines),
                            NSString(string: directory).expandingTildeInPath,
                            Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
                            healthURL.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            timeoutSeconds
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }
            .padding(14)
        }
        .frame(width: 540)
    }

    private var canRun: Bool {
        let resolvedDirectory = NSString(string: directory).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && FileManager.default.fileExists(atPath: resolvedDirectory, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && TemporaryTimeout.parse(timeoutText) != nil
            && (portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(portText) != nil)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url.path
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
