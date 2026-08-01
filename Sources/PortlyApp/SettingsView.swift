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
        }
        .frame(width: 560, height: 390)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(PortlyPreferences.showMenuBarItemKey) private var showMenuBarItem = true
    @AppStorage(PortlyPreferences.showMenuBarNameKey) private var showMenuBarName = false
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
