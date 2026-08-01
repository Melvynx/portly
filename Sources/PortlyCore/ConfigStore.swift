import Foundation

/// Reads and writes `~/.config/portly/config.json`, and watches it so a
/// hand-edit (or an agent writing the file directly) is picked up live.
public final class ConfigStore {
    public private(set) var config: PortlyConfig
    /// Called on the main queue after an external edit was loaded.
    public var onExternalChange: ((PortlyConfig) -> Void)?

    private let url: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private let debounce = DispatchQueue(label: "dev.portly.config.watch")
    private var pendingReload: DispatchWorkItem?
    /// Set while we are writing, so our own save does not bounce back as an external change.
    private var selfWriteUntil: Date = .distantPast

    public init(url: URL = PortlyPaths.configFile) {
        self.url = url
        PortlyPaths.ensureDirectories()
        self.config = ConfigStore.read(from: url) ?? PortlyConfig()
        if !FileManager.default.fileExists(atPath: url.path) {
            try? ConfigStore.write(config, to: url)
        }
    }

    // MARK: - IO

    public static func read(from url: URL) -> PortlyConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PortlyConfig.self, from: data)
    }

    public static func write(_ config: PortlyConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        PortlyPaths.ensureDirectories()
        try data.write(to: url, options: .atomic)
    }

    public func save() {
        selfWriteUntil = Date().addingTimeInterval(1.0)
        try? ConfigStore.write(config, to: url)
        // Atomic writes replace the inode, so the old watch is now dangling.
        restartWatchIfNeeded()
    }

    public func mutate(_ block: (inout PortlyConfig) -> Void) {
        block(&config)
        save()
    }

    public func reloadFromDisk() {
        if let fresh = ConfigStore.read(from: url) {
            config = fresh
        }
    }

    // MARK: - Watching

    public func startWatching() {
        stopWatching()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: debounce
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [fd] in close(fd) }
        watcher = source
        source.resume()
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
    }

    private func restartWatchIfNeeded() {
        guard watcher != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startWatching()
        }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-arm on the new inode after an atomic replace.
            DispatchQueue.main.async { self.startWatching() }
            guard Date() > self.selfWriteUntil else { return }
            guard let fresh = ConfigStore.read(from: self.url) else { return }
            DispatchQueue.main.async {
                self.config = fresh
                self.onExternalChange?(fresh)
            }
        }
        pendingReload = work
        debounce.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
