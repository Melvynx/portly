import Foundation
import PortlyCore

/// Plain-text log tail for a server: an in-memory ring buffer for the API and a
/// rotating file on disk. The terminal keeps its own styled scrollback, so this
/// side deliberately strips ANSI so `portly logs` output is readable by an agent.
final class LogStore {
    private let serverID: String
    private let maxLines: Int
    private let maxBytes: Int
    private let queue: DispatchQueue

    private var lines: [String] = []
    /// Kept as scalars, not Characters: Swift folds "\r\n" into a single
    /// grapheme cluster, so a Character-level search for "\n" never matches a
    /// PTY line ending.
    private var partial: [Unicode.Scalar] = []
    private var handle: FileHandle?
    private var bytesWritten: Int = 0

    init(serverID: String, maxLines: Int, maxMB: Int) {
        self.serverID = serverID
        self.maxLines = max(100, maxLines)
        self.maxBytes = max(1, maxMB) * 1_000_000
        self.queue = DispatchQueue(label: "dev.portly.log.\(serverID)")
        openFile()
    }

    // MARK: - Ingest

    func append(bytes: ArraySlice<UInt8>) {
        let chunk = String(decoding: bytes, as: UTF8.self)
        queue.async { self.ingest(chunk) }
    }

    /// Portly's own notes in the stream (start, restart, exit), so the log tail
    /// explains what happened without needing the UI.
    func note(_ message: String) {
        queue.async { self.ingest("[portly] \(message)\n") }
    }

    private func ingest(_ chunk: String) {
        partial.append(contentsOf: chunk.unicodeScalars)
        var cut = 0
        for (index, scalar) in partial.enumerated() where scalar == "\n" {
            // A PTY ends lines with CRLF; that trailing CR is a line ending, not
            // a carriage return that should wipe the line.
            var end = index
            if end > cut, partial[end - 1] == "\r" { end -= 1 }
            emitScalars(partial[cut..<end])
            cut = index + 1
        }
        if cut > 0 { partial.removeFirst(cut) }
        // A progress bar that only ever emits carriage returns would grow forever.
        if partial.count > 8000 {
            emitScalars(partial[...])
            partial.removeAll()
        }
    }

    private func emitScalars(_ scalars: ArraySlice<Unicode.Scalar>) {
        emit(LogStore.sanitize(String(String.UnicodeScalarView(scalars))))
    }

    private func emit(_ line: String) {
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        writeToFile(line)
    }

    // MARK: - Read

    func tail(_ count: Int) -> [String] {
        queue.sync {
            let n = min(max(1, count), lines.count)
            return Array(lines.suffix(n))
        }
    }

    func clear() {
        queue.async {
            self.lines.removeAll()
            self.partial.removeAll()
        }
    }

    // MARK: - File

    private func openFile() {
        PortlyPaths.ensureDirectories()
        let url = PortlyPaths.logFile(forServer: serverID)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        bytesWritten = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) .flatMap { $0 } ?? 0
        _ = try? handle?.seekToEnd()
    }

    private func writeToFile(_ line: String) {
        guard let handle else { return }
        let stamped = "\(LogStore.timestamp()) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        bytesWritten += data.count
        if bytesWritten > maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let url = PortlyPaths.logFile(forServer: serverID)
        let previous = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        bytesWritten = 0
        openFile()
    }

    // MARK: - Helpers

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func timestamp() -> String { formatter.string(from: Date()) }

    /// Drops ANSI/VT escape sequences and resolves carriage returns so a
    /// progress bar collapses to its final state instead of a wall of garbage.
    static func sanitize(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        let iterator = Array(input.unicodeScalars)
        var i = 0
        while i < iterator.count {
            let scalar = iterator[i]
            if scalar == "\u{1B}" {
                i += 1
                guard i < iterator.count else { break }
                let next = iterator[i]
                if next == "[" {
                    i += 1
                    // CSI: parameters then a final byte in @-~
                    while i < iterator.count, !("\u{40}"..."\u{7E}").contains(iterator[i]) { i += 1 }
                    i += 1
                } else if next == "]" {
                    // OSC: terminated by BEL or ESC \
                    i += 1
                    while i < iterator.count {
                        if iterator[i] == "\u{07}" { i += 1; break }
                        if iterator[i] == "\u{1B}", i + 1 < iterator.count, iterator[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
                } else {
                    i += 1
                }
                continue
            }
            if scalar == "\r" {
                out = String.UnicodeScalarView()
                i += 1
                continue
            }
            if scalar == "\u{07}" || scalar == "\u{08}" {
                i += 1
                continue
            }
            out.append(scalar)
            i += 1
        }
        return String(String.UnicodeScalarView(out))
    }
}
