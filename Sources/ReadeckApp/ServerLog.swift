import Foundation

/// The engine's log file.
///
/// The engine's stdout and stderr are redirected straight to this file rather
/// than through a pipe. That is deliberate:
///
///   * With a pipe, the read end dies with the launcher, and the engine's next
///     log write raises SIGPIPE — which Go deliberately lets kill a program
///     writing to a dead fd 1 or 2. An orphaned engine then self-destructs
///     within seconds, so "adopt the orphan" can never be relied on, and an
///     engine that happens not to log would linger holding the database.
///   * Output sitting in a pipe buffer when the launcher dies is lost, and this
///     log is the only place Readeck reports a fatal error.
///
/// A file makes the server's behaviour deterministic and the log complete.
final class ServerLog: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) {
        self.url = url
    }

    /// Rotates if the log has grown past `limit`, then returns an append handle
    /// for the child's stdout. Only called when spawning: an adopted engine is
    /// already writing to whatever file it was given, so rotating under it would
    /// split the log.
    func openForChild(limit: Int = 5 * 1024 * 1024) throws -> FileHandle {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int,
           size > limit {
            let previous = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: url, to: previous)
        }

        if !fileManager.fileExists(atPath: url.path) {
            _ = fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
        return handle
    }

    func tail(lines: Int = 12) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
