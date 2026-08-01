import Foundation

/// Reads a project folder and guesses the dev servers it can run, so adding a
/// server is picking a row instead of remembering the exact incantation.
///
/// Everything here is best-effort: a folder we cannot make sense of simply
/// yields no suggestions and the form stays a plain form.
enum CommandDetector {
    struct Suggestion: Identifiable, Hashable {
        let name: String
        let command: String
        let port: Int?
        let directory: String?
        /// Framework CLIs such as Vite accept a forwarded `--port` argument.
        let supportsPortArgument: Bool
        /// What the guess is based on, shown next to the row.
        let source: String
        var id: String { command + (directory ?? "") }

        init(
            name: String,
            command: String,
            port: Int?,
            directory: String?,
            supportsPortArgument: Bool = false,
            source: String
        ) {
            self.name = name
            self.command = command
            self.port = port
            self.directory = directory
            self.supportsPortArgument = supportsPortArgument
            self.source = source
        }
    }

    static func suggestions(inProjectRoot root: String, reservedPorts: Set<Int> = []) -> [Suggestion] {
        let base = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }

        var found = node(in: base, relativeTo: base)
        // A monorepo hides its real servers one level down.
        if found.isEmpty || isWorkspaceRoot(base) {
            for dir in workspaceCandidates(base) {
                found += node(in: dir, relativeTo: base)
            }
        }
        found += others(in: base, relativeTo: base)

        var seen = Set<String>()
        var availablePorts: [Int: Int] = [:]
        return found.filter { seen.insert($0.id).inserted }.map { suggestion in
            guard let port = suggestion.port else { return suggestion }
            let available = availablePorts[port] ?? nextAvailablePort(startingAt: port, reservedPorts: reservedPorts)
            availablePorts[port] = available
            let command = available != port && suggestion.supportsPortArgument
                ? "\(suggestion.command) -- --port \(available)"
                : suggestion.command
            return Suggestion(
                name: suggestion.name,
                command: command,
                port: available,
                directory: suggestion.directory,
                supportsPortArgument: suggestion.supportsPortArgument,
                source: suggestion.source
            )
        }
    }

    // MARK: - Node

    private static func node(in dir: URL, relativeTo base: URL) -> [Suggestion] {
        let packageURL = dir.appendingPathComponent("package.json")
        guard
            let data = try? Data(contentsOf: packageURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let scripts = json["scripts"] as? [String: String] ?? [:]
        guard !scripts.isEmpty else { return [] }

        let runner = packageManager(in: dir)
        let deps = dependencyNames(json)
        let envPort = portFromEnvFiles(in: dir)
        let relative = relativePath(dir, from: base)
        let label = relative.map { "\($0)/package.json" } ?? "package.json"

        return devScriptNames(scripts.keys).map { key in
            let script = scripts[key] ?? ""
            let configuredPort = portFromScript(script) ?? envPort
            let detectedFrameworkPort = frameworkPort(deps: deps, script: script)
            return Suggestion(
                name: serverName(script: key, directory: relative),
                command: "\(runner) \(key)",
                port: configuredPort ?? detectedFrameworkPort,
                directory: relative,
                supportsPortArgument: configuredPort == nil && detectedFrameworkPort != nil,
                source: label
            )
        }
    }

    /// `dev` and `start` first, then anything that looks like a second server
    /// (`dev:api`, `start:worker`), then `serve`.
    private static func devScriptNames(_ keys: some Collection<String>) -> [String] {
        let all = Set(keys)
        var ordered: [String] = []
        for preferred in ["dev", "start", "serve", "develop", "watch"] where all.contains(preferred) {
            ordered.append(preferred)
        }
        let namespaced = all
            .filter { $0.hasPrefix("dev:") || $0.hasPrefix("start:") || $0.hasPrefix("serve:") }
            .sorted()
        ordered.append(contentsOf: namespaced)
        return Array(ordered.prefix(8))
    }

    private static func packageManager(in dir: URL) -> String {
        let fm = FileManager.default
        let lockfiles = [
            ("pnpm-lock.yaml", "pnpm"),
            ("bun.lockb", "bun run"),
            ("bun.lock", "bun run"),
            ("yarn.lock", "yarn"),
            ("package-lock.json", "npm run"),
        ]
        for (file, command) in lockfiles where fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
            return command
        }
        // A workspace package inherits the lockfile of its root.
        let parent = dir.deletingLastPathComponent()
        for (file, command) in lockfiles where fm.fileExists(atPath: parent.appendingPathComponent(file).path) {
            return command
        }
        return "npm run"
    }

    private static func dependencyNames(_ json: [String: Any]) -> Set<String> {
        var names = Set<String>()
        for key in ["dependencies", "devDependencies"] {
            if let dict = json[key] as? [String: Any] { names.formUnion(dict.keys) }
        }
        return names
    }

    // MARK: - Non-node stacks

    private static func others(in dir: URL, relativeTo base: URL) -> [Suggestion] {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        let relative = relativePath(dir, from: base)
        var out: [Suggestion] = []

        if has("Cargo.toml") {
            out.append(Suggestion(name: "server", command: "cargo run", port: nil, directory: relative, source: "Cargo.toml"))
        }
        if has("go.mod") {
            out.append(Suggestion(name: "server", command: "go run .", port: nil, directory: relative, source: "go.mod"))
        }
        if has("manage.py") {
            out.append(Suggestion(name: "django", command: "python manage.py runserver", port: 8000, directory: relative, source: "manage.py"))
        }
        if has("Gemfile"), has("config.ru") {
            out.append(Suggestion(name: "rails", command: "bin/rails server", port: 3000, directory: relative, source: "Gemfile"))
        }
        if has("docker-compose.yml") || has("compose.yml") {
            out.append(Suggestion(name: "compose", command: "docker compose up", port: nil, directory: relative, source: "docker-compose"))
        }
        if has("Procfile"), let procfile = try? String(contentsOf: dir.appendingPathComponent("Procfile"), encoding: .utf8) {
            for line in procfile.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let command = parts[1].trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty else { continue }
                out.append(Suggestion(
                    name: String(parts[0]).trimmingCharacters(in: .whitespaces),
                    command: command,
                    port: portFromScript(command),
                    directory: relative,
                    source: "Procfile"
                ))
            }
        }
        return out
    }

    // MARK: - Ports

    /// `--port 3001`, `-p 3001`, `PORT=3001`.
    private static func portFromScript(_ script: String) -> Int? {
        let patterns = [
            #"PORT=\$\{PORT:-(\d{2,5})\}"#,
            #"--port[= ]+(\d{2,5})"#,
            #"(?:^|\s)-p[= ]+(\d{2,5})"#,
            #"PORT[= ]+(\d{2,5})"#,
        ]
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                let range = Range(match.range(at: 1), in: script),
                let port = Int(script[range])
            else { continue }
            return port
        }
        return nil
    }

    private static func nextAvailablePort(startingAt port: Int, reservedPorts: Set<Int>) -> Int {
        for candidate in port...65_535 {
            if !reservedPorts.contains(candidate), PortInspector.occupant(of: candidate) == nil {
                return candidate
            }
        }
        return port
    }

    private static func portFromEnvFiles(in dir: URL) -> Int? {
        for name in [".env.local", ".env.development", ".env"] {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("PORT=") else { continue }
                let value = trimmed.dropFirst("PORT=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if let port = Int(value) { return port }
            }
        }
        return nil
    }

    private static func frameworkPort(deps: Set<String>, script: String) -> Int? {
        let table: [(String, Int)] = [
            ("astro", 4321),
            ("@remix-run/dev", 3000),
            ("next", 3000),
            ("nuxt", 3000),
            ("@sveltejs/kit", 5173),
            ("vite", 5173),
            ("expo", 8081),
            ("@angular/cli", 4200),
            ("react-scripts", 3000),
            ("convex", 3210),
        ]
        for (dependency, port) in table where deps.contains(dependency) || script.contains(dependency) {
            return port
        }
        return nil
    }

    // MARK: - Workspaces

    private static func isWorkspaceRoot(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("pnpm-workspace.yaml").path) { return true }
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["workspaces"] != nil
    }

    private static func workspaceCandidates(_ base: URL) -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        for container in ["apps", "packages", "services"] {
            let url = base.appendingPathComponent(container)
            guard let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            dirs += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return Array(dirs.prefix(12))
    }

    // MARK: - Naming

    private static func serverName(script: String, directory: String?) -> String {
        // In a monorepo the folder is what tells servers apart, not "dev".
        if let directory {
            let leaf = directory.split(separator: "/").last.map(String.init) ?? directory
            if script == "dev" || script == "start" { return leaf }
            return "\(leaf)-\(script.replacingOccurrences(of: ":", with: "-"))"
        }
        return script.replacingOccurrences(of: ":", with: "-")
    }

    private static func relativePath(_ url: URL, from base: URL) -> String? {
        let path = url.standardizedFileURL.path
        let root = base.standardizedFileURL.path
        guard path != root, path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }
}
