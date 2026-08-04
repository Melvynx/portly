import AppKit
import PortlyCore
import ServiceManagement
import SwiftUI

enum PortlyPreferences {
    static let showMenuBarItemKey = "showMenuBarItem"
    static let showMenuBarNameKey = "showMenuBarName"
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RuntimeSettingsView()
                .tabItem { Label("Servers", systemImage: "server.rack") }
            MemoryGuardSettingsView()
                .tabItem { Label("Memory", systemImage: "memorychip") }
        }
        .frame(width: 680, height: 560)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(PortlyPreferences.showMenuBarItemKey) private var showMenuBarItem = true
    @AppStorage(PortlyPreferences.showMenuBarNameKey) private var showMenuBarName = false
    @AppStorage("agentOnboardingDismissed") private var agentOnboardingDismissed = false
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show Portly in the menu bar", isOn: $showMenuBarItem)

                Picker("Appearance", selection: $showMenuBarName) {
                    Text("Icon only").tag(false)
                    Text("Icon and name").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!showMenuBarItem)

                Text("Hold Command and drag Portly to reposition it in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch Portly at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: updateLaunchAtLogin
                ))

                Text("Closing the main window keeps Portly and its managed servers running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Configuration") {
                LabeledContent("Config file") {
                    Text(NSString(string: PortlyPaths.configFile.path).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Reveal Config File") {
                    NSWorkspace.shared.activateFileViewerSelecting([PortlyPaths.configFile])
                }
            }

            Section("Portly") {
                LabeledContent("Version", value: appVersion)
                Button("Check for Updates…") {
                    PortlyUpdater.shared.checkForUpdates()
                }
                Button("Show Agent Setup") {
                    agentOnboardingDismissed = false
                    WindowOpener.openMainWindow()
                }
            }
        }
        .formStyle(.grouped)
        .task { launchAtLogin = SMAppService.mainApp.status == .enabled }
        .alert("Unable to update login setting", isPresented: Binding(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginItemError ?? "The login setting could not be changed.")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? portlyVersion
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        Task {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
                loginItemError = error.localizedDescription
            }
        }
    }
}

private struct RuntimeSettingsView: View {
    @EnvironmentObject private var supervisor: Supervisor
    @State private var healthIntervalSeconds = 10
    @State private var maxRestartAttempts = 5
    @State private var logBufferLines = 5_000
    @State private var logFileMaxMB = 10
    @State private var saved = false

    var body: some View {
        Form {
            Section("Health checks") {
                Stepper(
                    "Check every \(healthIntervalSeconds) seconds",
                    value: $healthIntervalSeconds,
                    in: 2...120
                )
                Stepper(
                    "Stop after \(maxRestartAttempts) failed restart \(maxRestartAttempts == 1 ? "attempt" : "attempts")",
                    value: $maxRestartAttempts,
                    in: 1...20
                )
                Text("Portly restarts unhealthy servers only when automatic restart is enabled for that server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logs") {
                Stepper(
                    "Keep \(logBufferLines.formatted()) lines per server",
                    value: $logBufferLines,
                    in: 500...50_000,
                    step: 500
                )
                Stepper(
                    "Rotate log files after \(logFileMaxMB) MB",
                    value: $logFileMaxMB,
                    in: 1...100
                )
            }

            Section {
                HStack {
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Save Settings", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: healthIntervalSeconds) { saved = false }
        .onChange(of: maxRestartAttempts) { saved = false }
        .onChange(of: logBufferLines) { saved = false }
        .onChange(of: logFileMaxMB) { saved = false }
    }

    private var hasChanges: Bool {
        let settings = supervisor.settings
        return healthIntervalSeconds != settings.healthIntervalSeconds
            || maxRestartAttempts != settings.maxRestartAttempts
            || logBufferLines != settings.logBufferLines
            || logFileMaxMB != settings.logFileMaxMB
    }

    private func load() {
        let settings = supervisor.settings
        healthIntervalSeconds = settings.healthIntervalSeconds
        maxRestartAttempts = settings.maxRestartAttempts
        logBufferLines = settings.logBufferLines
        logFileMaxMB = settings.logFileMaxMB
    }

    private func save() {
        supervisor.updateRuntimeSettings(
            healthIntervalSeconds: healthIntervalSeconds,
            maxRestartAttempts: maxRestartAttempts,
            logBufferLines: logBufferLines,
            logFileMaxMB: logFileMaxMB
        )
        saved = true
    }
}

private struct MemoryGuardSettingsView: View {
    @EnvironmentObject private var supervisor: Supervisor
    @State private var editingMemoryLimit: MemoryLimitEditorTarget?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Automatic memory guard", systemImage: "shield.lefthalf.filled")
                        .font(PortlyTypography.bodyMedium)
                    Text("Portly measures each project's total footprint every two seconds. Three consecutive samples above its limit restart every running server in that project, then sampling starts fresh on the new processes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("Global default") {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(supervisor.settings.globalMemoryLimitBytes.map(MemorySize.display) ?? "Off")
                            .font(PortlyTypography.bodyMedium)
                        Text(supervisor.settings.globalMemoryLimitBytes == nil
                            ? "Memory restarts are off for projects using the global default"
                            : "Applied separately to every project using the global default")
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Edit…") { editingMemoryLimit = .global }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Edit global memory limit")
                }
            }

            Section("Projects") {
                if supervisor.projects.isEmpty {
                    Text("No projects configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(supervisor.projects) { project in
                        projectRow(project)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingMemoryLimit) { target in
            MemoryLimitEditor(
                target: target,
                globalLimitBytes: supervisor.settings.globalMemoryLimitBytes
            ) { mode, bytes in
                switch target {
                case .global:
                    supervisor.updateGlobalMemoryLimit(mode == .custom ? bytes : nil)
                case .project(let project):
                    supervisor.updateProjectMemoryLimit(projectID: project.id, mode: mode, bytes: bytes)
                }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let limit = project.effectiveMemoryLimit(global: supervisor.settings.globalMemoryLimitBytes)
        let footprint = supervisor.projectResourceHistory.last(where: { $0.projectID == project.id })?.footprintBytes ?? 0
        let ratio = limit.map { min(Double(footprint) / Double(max($0, 1)), 1) } ?? 0
        let color: Color = limit == nil ? .secondary : ratio >= 0.8 ? .orange : .green

        return HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: project.color))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(project.name)
                        .font(PortlyTypography.bodyMedium)
                    Text(policyLabel(project.memoryLimitMode))
                        .font(PortlyTypography.label)
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .frame(height: 19)
                        .background(color.opacity(0.1), in: Capsule())
                }

                if let limit {
                    ProgressView(value: ratio)
                        .tint(color)
                        .frame(maxWidth: 280)
                    Text("\(MemorySize.display(footprint)) of \(MemorySize.display(limit))")
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Automatic restart disabled")
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                }

                if let event = supervisor.memoryLimitRestarts[project.id] {
                    Label(
                        "Last automatic restart: \(event.timestamp.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "arrow.clockwise"
                    )
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button("Edit…") { editingMemoryLimit = .project(project) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Edit memory limit for \(project.name)")
        }
        .padding(.vertical, 4)
    }

    private func policyLabel(_ mode: MemoryLimitMode) -> String {
        switch mode {
        case .inherit: return "GLOBAL"
        case .custom: return "CUSTOM"
        case .disabled: return "OFF"
        }
    }
}

private enum MemoryLimitEditorTarget: Identifiable {
    case global
    case project(Project)

    var id: String {
        switch self {
        case .global: return "global"
        case .project(let project): return project.id
        }
    }

    var title: String {
        switch self {
        case .global: return "Global memory guard"
        case .project(let project): return "Memory guard · \(project.name)"
        }
    }
}

private struct MemoryLimitEditor: View {
    let target: MemoryLimitEditorTarget
    let globalLimitBytes: UInt64?
    let onSave: (MemoryLimitMode, UInt64?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: MemoryLimitMode
    @State private var value: String
    @State private var showValidationError = false
    @FocusState private var valueFocused: Bool

    init(
        target: MemoryLimitEditorTarget,
        globalLimitBytes: UInt64?,
        onSave: @escaping (MemoryLimitMode, UInt64?) -> Void
    ) {
        self.target = target
        self.globalLimitBytes = globalLimitBytes
        self.onSave = onSave

        let initialMode: MemoryLimitMode
        let initialBytes: UInt64?
        switch target {
        case .global:
            initialMode = globalLimitBytes == nil ? .disabled : .custom
            initialBytes = globalLimitBytes
        case .project(let project):
            initialMode = project.memoryLimitMode
            initialBytes = project.memoryLimitBytes ?? globalLimitBytes
        }
        _mode = State(initialValue: initialMode)
        _value = State(initialValue: initialBytes.map {
            MemorySize.display($0).replacingOccurrences(of: " ", with: "")
        } ?? "5GB")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(PortlyTypography.title)
                    Text("Automatic restart policy")
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            Form {
                Section {
                    Picker("Policy", selection: $mode) {
                        if case .project = target {
                            Text("Inherit global limit").tag(MemoryLimitMode.inherit)
                        }
                        Text("Disabled").tag(MemoryLimitMode.disabled)
                        Text("Custom limit").tag(MemoryLimitMode.custom)
                    }
                    .pickerStyle(.radioGroup)

                    if mode == .custom {
                        TextField("Limit", text: $value)
                            .focused($valueFocused)
                            .accessibilityHint(validationMessage)

                        Text(validationMessage)
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(showValidationError && parsedValue == nil ? Color.red : Color.secondary)
                    }
                }

                Section("How it works") {
                    Text(explanation)
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                    Label("Three consecutive samples above the limit", systemImage: "clock.arrow.2.circlepath")
                    Label("Sampling resets after each restart", systemImage: "arrow.counterclockwise")
                    Label("All running servers in an affected project restart together", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(PortlyTypography.metadata)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if mode == .custom, parsedValue == nil {
                        showValidationError = true
                        valueFocused = true
                        return
                    }
                    onSave(mode, mode == .custom ? parsedValue : nil)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 500, height: 410)
    }

    private var explanation: String {
        switch target {
        case .global:
            return "The global value is a default applied separately to every project that inherits it. It is not a combined limit for the whole machine."
        case .project:
            if mode == .inherit {
                return globalLimitBytes.map {
                    "This project currently inherits \(MemorySize.display($0)) from the global setting."
                } ?? "The global guard is off, so inheritance currently leaves this project unprotected."
            }
            return "This policy applies only to this project and overrides the global setting."
        }
    }

    private var parsedValue: UInt64? {
        MemorySize.parse(value)
    }

    private var validationMessage: String {
        if showValidationError, parsedValue == nil {
            return "Enter a size of at least 64 MB, for example 5GB."
        }
        return "Examples: 512MB, 5GB, or 5Go. Minimum: 64 MB."
    }
}
