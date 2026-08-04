import Foundation
import SwiftUI

@MainActor
final class AgentSetup: ObservableObject {
    @Published private(set) var skillInstalled = false
    @Published private(set) var rulesInstalled = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let fileManager = FileManager.default

    private var agentsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".agents", isDirectory: true)
    }

    private var skillDirectory: URL {
        agentsDirectory
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("portly", isDirectory: true)
    }

    private var globalRuleFiles: [URL] {
        [
            agentsDirectory.appendingPathComponent("AGENTS.md"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("CLAUDE.md"),
        ]
    }

    init() {
        refresh()
    }

    func refresh() {
        skillInstalled = fileManager.fileExists(atPath: skillDirectory.appendingPathComponent("SKILL.md").path)
        rulesInstalled = globalRuleFiles.allSatisfy(hasCurrentPortlyRule)
    }

    func installSkill() {
        perform {
            guard let source = bundledSkillDirectory else {
                throw SetupError.missingBundledSkill
            }

            let skillsRoot = skillDirectory.deletingLastPathComponent()
            try fileManager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)

            let staging = skillsRoot.appendingPathComponent(".portly-install-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: source, to: staging)

            if fileManager.fileExists(atPath: skillDirectory.path) {
                try fileManager.removeItem(at: skillDirectory)
            }
            try fileManager.moveItem(at: staging, to: skillDirectory)

            try installBundledCLIIfPossible()
        }
    }

    func installGlobalRules() {
        perform {
            for configuredFile in globalRuleFiles {
                let file = configuredFile.resolvingSymlinksInPath()
                try fileManager.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let updated = Self.installManagedRule(in: contents)
                if updated != contents {
                    try updated.write(to: file, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            refresh()
        }

        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func hasCurrentPortlyRule(_ file: URL) -> Bool {
        guard let contents = try? String(contentsOf: file.resolvingSymlinksInPath(), encoding: .utf8) else {
            return false
        }
        return contents.contains("portly:managed-rule:start")
            && contents.contains("exits with code `124`")
    }

    private var bundledSkillDirectory: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("portly-skill", isDirectory: true)
        if let bundled, fileManager.fileExists(atPath: bundled.appendingPathComponent("SKILL.md").path) {
            return bundled
        }

        // Keeps `swift run PortlyApp` useful for contributors without changing
        // the downloadable app's resource lookup.
        let checkout = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("skills/portly", isDirectory: true)
        return fileManager.fileExists(atPath: checkout.appendingPathComponent("SKILL.md").path)
            ? checkout
            : nil
    }

    private func installBundledCLIIfPossible() throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("portly-cli"),
              fileManager.isExecutableFile(atPath: source.path)
        else { return }

        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("portly")
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    private static let managedRule = """
    <!-- portly:managed-rule:start -->
    ## Development servers

    - Always use Portly (`portly ...`) to start, stop, restart, inspect, or keep local development servers running.
    - Start with `portly status`. Use `portly status --details` only for the full inventory and metrics, and `--json` only for machine-readable fields. Reuse a healthy managed server; if an in-scope server is running outside Portly, register it and use `portly take-over <project/server> --json`.
    - For long-lived or reusable work, create a project and server.
    - For builds, tests, code generation, previews, demos, and other bounded one-off work, run `job_id="$(portly temp '<command>' --path <folder> --timeout 30m)"`, then `portly wait "$job_id"`. `temp` returns immediately with an ID; `wait` prints captured logs and exits with the command's real code. A timeout kills the whole process group and exits with code `124`.
    - Never launch persistent development servers directly, in the background, or through another supervisor.
    <!-- portly:managed-rule:end -->
    """

    static func installManagedRule(in contents: String) -> String {
        let startMarker = "<!-- portly:managed-rule:start -->"
        let endMarker = "<!-- portly:managed-rule:end -->"
        if let start = contents.range(of: startMarker),
           let end = contents.range(of: endMarker, range: start.lowerBound..<contents.endIndex) {
            var updated = contents
            updated.replaceSubrange(start.lowerBound..<end.upperBound, with: managedRule)
            return updated
        }

        var updated = contents
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        if !updated.isEmpty { updated += "\n" }
        updated += managedRule
        if !updated.hasSuffix("\n") { updated += "\n" }
        return updated
    }

    private enum SetupError: LocalizedError {
        case missingBundledSkill

        var errorDescription: String? {
            "Portly could not find its bundled agent skill. Reinstall the latest version and try again."
        }
    }
}

struct AgentOnboardingCard: View {
    @ObservedObject var setup: AgentSetup
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: setupComplete ? "checkmark.seal.fill" : "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(setupComplete ? .green : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill((setupComplete ? Color.green : Color.accentColor).opacity(0.12))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(setupComplete ? "You’re good to go" : "Let’s set up Portly for your agents")
                        .font(PortlyTypography.project)
                    Text(setupComplete
                        ? "Work as you always do. Your agents now know to use Portly automatically."
                        : "Two quick steps give your coding agents the Portly skill and global server rules.")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if setupComplete {
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Not now", action: onDismiss)
                        .buttonStyle(.borderless)
                }
            }

            if !setupComplete {
                HStack(spacing: 10) {
                    SetupStep(
                        number: 1,
                        title: setup.skillInstalled ? "Skill installed" : "Set up the Portly skill",
                        detail: "Installs the skill and bundled CLI for your coding agents.",
                        isComplete: setup.skillInstalled
                    ) {
                        Button(setup.skillInstalled ? "Installed" : "Install Skill") {
                            setup.installSkill()
                        }
                        .buttonStyle(.bordered)
                        .disabled(setup.skillInstalled || setup.isWorking)
                    }

                    SetupStep(
                        number: 2,
                        title: setup.rulesInstalled ? "Global rules installed" : "Set up global agent rules",
                        detail: "Updates AGENTS.md and CLAUDE.md without replacing your existing rules.",
                        isComplete: setup.rulesInstalled
                    ) {
                        Button(setup.rulesInstalled ? "Installed" : "Install Rules") {
                            setup.installGlobalRules()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!setup.skillInstalled || setup.rulesInstalled || setup.isWorking)
                    }
                }
            }

            if let error = setup.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Portly agent setup")
    }

    private var setupComplete: Bool {
        setup.skillInstalled && setup.rulesInstalled
    }
}

private struct SetupStep<Accessory: View>: View {
    let number: Int
    let title: String
    let detail: String
    let isComplete: Bool
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "\(number).circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isComplete ? .green : Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PortlyTypography.bodyMedium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
            accessory
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
    }
}
