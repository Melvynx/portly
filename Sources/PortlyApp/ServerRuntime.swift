import AppKit
import Foundation
import PortlyCore
import SwiftTerm

/// Supervises one server: PTY process, terminal, health checks and restarts.
///
/// The terminal view is owned here rather than by the SwiftUI view so scrollback
/// survives closing and reopening the window, and so a server keeps running with
/// no window on screen.
final class ServerRuntime: NSObject, ObservableObject, LocalProcessDelegate, TerminalViewDelegate {
    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var healthy: Bool = false
    @Published private(set) var pid: Int32?
    @Published private(set) var startedAt: Date?
    @Published private(set) var restartCount: Int = 0
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var lastError: String?

    let id: String
    private(set) var config: ServerConfig
    private(set) var projectID: String
    private(set) var projectName: String
    private(set) var projectRoot: String

    private var settings: PortlyConfig
    private let logs: LogStore
    private var process: LocalProcess?
    private var terminal: TerminalView?

    /// Set while a stop was requested by the user or an agent, so the exit is not
    /// treated as a crash.
    private var manualStop = false
    private var healthTimer: Timer?
    private var restartWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?
    private var takeoverPending = false
    private var consecutiveHealthFailures = 0
    private var lastHealthyAt: Date?

    /// Called when a server lands in `.failed`, for the macOS notification.
    var onFailed: ((ServerRuntime) -> Void)?
    /// Called whenever observable state changes, so the menu bar can refresh.
    var onStateChange: (() -> Void)?

    init(config: ServerConfig, project: Project, settings: PortlyConfig) {
        self.id = config.id
        self.config = config
        self.projectID = project.id
        self.projectName = project.name
        self.projectRoot = project.root
        self.settings = settings
        self.logs = LogStore(
            serverID: config.id,
            maxLines: settings.logBufferLines,
            maxMB: settings.logFileMaxMB
        )
        super.init()
    }

    // MARK: - Derived

    var isRunning: Bool {
        switch state {
        case .starting, .running, .unhealthy, .restarting: return true
        case .stopped, .failed: return false
        }
    }

    var workingDirectory: String {
        guard let dir = config.directory, !dir.isEmpty else { return expand(projectRoot) }
        if dir.hasPrefix("/") || dir.hasPrefix("~") { return expand(dir) }
        return URL(fileURLWithPath: expand(projectRoot)).appendingPathComponent(dir).path
    }

    var url: String? {
        guard let port = config.port else { return nil }
        return "http://localhost:\(port)"
    }

    var status: ServerStatus {
        ServerStatus(
            id: id,
            name: config.name,
            projectID: projectID,
            projectName: projectName,
            command: config.command,
            port: config.port,
            directory: workingDirectory,
            state: state,
            pid: pid,
            startedAt: startedAt,
            restartCount: restartCount,
            lastExitCode: lastExitCode,
            lastError: lastError,
            healthy: healthy,
            url: url
        )
    }

    private func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    // MARK: - Terminal

    /// The live terminal for this server, created on first display and kept alive.
    /// Must be called on the main thread.
    func terminalView() -> TerminalView {
        if let terminal { return terminal }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        view.terminalDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeForegroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.88, green: 0.9, blue: 0.92, alpha: 1)
                : NSColor(srgbRed: 0.16, green: 0.18, blue: 0.21, alpha: 1)
        }
        view.nativeBackgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.055, green: 0.065, blue: 0.08, alpha: 1)
                : NSColor(srgbRed: 0.975, green: 0.98, blue: 0.985, alpha: 1)
        }
        terminal = view
        return view
    }

    // MARK: - Lifecycle

    func apply(config: ServerConfig, project: Project, settings: PortlyConfig) {
        let healthIntervalChanged = self.settings.healthIntervalSeconds != settings.healthIntervalSeconds
        self.config = config
        self.projectID = project.id
        self.projectName = project.name
        self.projectRoot = project.root
        self.settings = settings
        logs.updateLimits(maxLines: settings.logBufferLines, maxMB: settings.logFileMaxMB)
        if healthIntervalChanged, isRunning { startHealthTimer() }
    }

    func start() {
        guard !isRunning else { return }
        takeoverPending = false
        restartWork?.cancel()
        restartWork = nil
        manualStop = false
        consecutiveHealthFailures = 0
        spawn()
    }

    /// Restart requested by a human or an agent: the counter is reset, this is
    /// not a crash loop.
    func restart() {
        restartCount = 0
        if isRunning {
            stop(then: { [weak self] in self?.start() })
        } else {
            start()
        }
    }

    func stop(then completion: (() -> Void)? = nil) {
        guard let process, process.running, process.shellPid > 0 else {
            takeoverPending = false
            setState(.stopped)
            completion?()
            return
        }
        manualStop = true
        stopHealthTimer()
        restartWork?.cancel()
        restartWork = nil
        pendingStopCompletion = completion

        let group = process.shellPid
        logs.note("stopping (SIGTERM to process group \(group))")
        // The whole group, otherwise dev servers leave orphans holding the port.
        kill(-group, SIGTERM)
        kill(group, SIGTERM)

        let work = DispatchWorkItem { [weak self] in
            guard let self, let proc = self.process, proc.running else { return }
            self.logs.note("did not exit in 5s, sending SIGKILL")
            kill(-group, SIGKILL)
            kill(group, SIGKILL)
        }
        killWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private var pendingStopCompletion: (() -> Void)?

    private func spawn() {
        setState(.starting)
        lastError = nil
        healthy = false
        consecutiveHealthFailures = 0

        if let port = config.port, let occupant = PortInspector.occupant(of: port) {
            lastError = "Port \(port) is already used by \(occupant.command) (pid \(occupant.pid))"
            logs.note("cannot start, \(lastError!)")
            setState(.failed)
            onFailed?(self)
            return
        }

        let dir = workingDirectory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            lastError = "Directory not found: \(dir)"
            logs.note("cannot start, directory not found: \(dir)")
            setState(.failed)
            onFailed?(self)
            return
        }

        let proc = LocalProcess(delegate: self)
        process = proc

        logs.note("starting: \(config.command)  (cwd: \(dir))")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let view = self.terminalView()
            view.feed(text: "\u{1B}[2m[portly] \(self.config.command)\u{1B}[0m\r\n")
            proc.startProcess(
                executable: "/bin/zsh",
                args: ["-l", "-c", self.config.command],
                environment: self.environmentArray(),
                execName: nil,
                currentDirectory: dir
            )
            self.pid = proc.shellPid
            self.startedAt = Date()
            self.startHealthTimer()
            self.onStateChange?()
        }
    }

    /// A login shell gives us the user's real PATH (nvm, mise, homebrew), which a
    /// bare exec would not have.
    private func environmentArray() -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Portly owns a real PTY. Do not inherit NO_COLOR from the app launcher
        // or an agent shell: it would flatten Vite, pnpm and other rich output.
        env.removeValue(forKey: "NO_COLOR")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["FORCE_COLOR"] = "1"
        env["CLICOLOR"] = "1"
        env["CLICOLOR_FORCE"] = "1"
        env["TERM_PROGRAM"] = "Portly"
        env["PORTLY"] = "1"
        env["PORTLY_SERVER"] = config.name
        if let port = config.port {
            env["PORT"] = String(port)
        }
        for (k, v) in config.env { env[k] = v }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Stop a listener launched outside Portly, then start this configured
    /// server as soon as the port is released. The explicit UI/CLI action is
    /// the authority boundary; Portly never takes over automatically.
    @discardableResult
    func takeOverPort() -> Bool {
        guard !isRunning, let port = config.port, let occupant = PortInspector.occupant(of: port) else {
            return false
        }
        logs.note("taking over port \(port) from \(occupant.command) (pid \(occupant.pid))")
        guard PortInspector.kill(pid: occupant.pid) else {
            lastError = "Unable to stop \(occupant.command) (pid \(occupant.pid))"
            setState(.failed)
            return false
        }
        takeoverPending = true
        lastError = "Waiting for port \(port) to be released"
        setState(.starting)
        terminal?.feed(text: "\u{1B}[33m[portly] moving port \(port) from \(occupant.command)…\u{1B}[0m\r\n")
        waitForPortRelease(port: port, attemptsRemaining: 25)
        return true
    }

    private func waitForPortRelease(port: Int, attemptsRemaining: Int) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let occupied = PortInspector.isListening(port: port)
            DispatchQueue.main.async {
                guard self.takeoverPending else { return }
                if !occupied {
                    self.takeoverPending = false
                    self.lastError = nil
                    self.spawn()
                } else if attemptsRemaining > 1 {
                    self.waitForPortRelease(port: port, attemptsRemaining: attemptsRemaining - 1)
                } else {
                    self.takeoverPending = false
                    self.lastError = "Port \(port) was not released after 5 seconds"
                    self.logs.note(self.lastError!)
                    self.setState(.failed)
                }
            }
        }
    }

    // MARK: - Health

    private func startHealthTimer() {
        stopHealthTimer()
        let interval = TimeInterval(max(2, settings.healthIntervalSeconds))
        // Probe quickly at first so a server that binds fast turns green fast.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { return }
            if self.state == .running || self.state == .unhealthy {
                if t.timeInterval != interval {
                    self.stopHealthTimer()
                    self.startSteadyHealthTimer(interval: interval)
                    return
                }
            }
            self.runHealthCheck()
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startSteadyHealthTimer(interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.runHealthCheck()
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func runHealthCheck() {
        guard isRunning, let proc = process, proc.running else { return }
        HealthChecker.check(server: config) { [weak self] ok in
            DispatchQueue.main.async { self?.handleHealthResult(ok) }
        }
    }

    private func handleHealthResult(_ ok: Bool) {
        guard isRunning else { return }
        healthy = ok

        if ok {
            consecutiveHealthFailures = 0
            lastHealthyAt = Date()
            if state != .running { setState(.running) }
            onStateChange?()
            return
        }

        // Grace period: a starting server has not bound its port yet.
        if state == .starting {
            onStateChange?()
            return
        }

        consecutiveHealthFailures += 1
        if state == .running { setState(.unhealthy) }
        // Three misses in a row is a hung server, not a blip.
        if consecutiveHealthFailures >= 3, config.autoRestart {
            logs.note("health check failed \(consecutiveHealthFailures)x, restarting")
            consecutiveHealthFailures = 0
            stop(then: { [weak self] in self?.handleCrashRestart(reason: "unhealthy") })
        }
        onStateChange?()
    }

    // MARK: - Restart policy

    private func handleCrashRestart(reason: String) {
        guard config.autoRestart else {
            setState(.stopped)
            return
        }
        // A server that stayed healthy for a while gets a clean slate.
        if let last = lastHealthyAt, Date().timeIntervalSince(last) > 30 {
            restartCount = 0
        }
        guard restartCount < settings.maxRestartAttempts else {
            lastError = "Gave up after \(restartCount) restart attempts (\(reason))"
            logs.note("giving up after \(restartCount) restart attempts")
            setState(.failed)
            onFailed?(self)
            return
        }

        restartCount += 1
        let delay = min(30.0, pow(2.0, Double(restartCount - 1)))
        setState(.restarting)
        logs.note("restart \(restartCount)/\(settings.maxRestartAttempts) in \(Int(delay))s (\(reason))")

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .restarting else { return }
            self.manualStop = false
            self.spawn()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setState(_ new: ServerState) {
        guard state != new else { return }
        state = new
        if new == .stopped || new == .failed {
            healthy = false
            pid = nil
            if new == .stopped { startedAt = nil }
        }
        onStateChange?()
    }

    // MARK: - LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.killWork?.cancel()
            self.killWork = nil
            self.stopHealthTimer()
            self.lastExitCode = exitCode
            self.pid = nil
            self.healthy = false
            self.process = nil

            let code = exitCode.map(String.init) ?? "signal"
            self.logs.note("process exited (\(code))")
            self.terminal?.feed(text: "\r\n\u{1B}[2m[portly] exited (\(code))\u{1B}[0m\r\n")

            if self.manualStop {
                self.manualStop = false
                self.setState(.stopped)
                let completion = self.pendingStopCompletion
                self.pendingStopCompletion = nil
                completion?()
            } else {
                self.handleCrashRestart(reason: "exit \(code)")
            }
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        logs.append(bytes: slice)
        DispatchQueue.main.async { [weak self] in
            self?.terminal?.feed(byteArray: slice)
        }
    }

    func getWindowSize() -> winsize {
        guard let terminal = terminal else {
            return winsize(ws_row: UInt16(30), ws_col: UInt16(100), ws_xpixel: 0, ws_ypixel: 0)
        }
        let t = terminal.getTerminal()
        return winsize(
            ws_row: UInt16(t.rows), ws_col: UInt16(t.cols),
            ws_xpixel: UInt16(terminal.frame.width), ws_ypixel: UInt16(terminal.frame.height)
        )
    }

    // MARK: - TerminalViewDelegate (keyboard goes back to the process)

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process?.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let process, process.running, process.childfd >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(newRows), ws_col: UInt16(newCols),
            ws_xpixel: 0, ws_ypixel: 0
        )
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func bell(source: TerminalView) {}

    // MARK: - Logs

    func logTail(_ count: Int) -> [String] { logs.tail(count) }

    func clearTerminal() {
        DispatchQueue.main.async { [weak self] in
            self?.terminal?.getTerminal().resetToInitialState()
            self?.terminal?.setNeedsDisplay(self?.terminal?.bounds ?? .zero)
        }
        logs.clear()
    }
}
