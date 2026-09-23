import Foundation

/// Appends the engine's stdout to one file, rotating once per launch.
///
/// Readeck writes everything to stdout — including fatal `ERROR:` lines — and
/// never to stderr, so this is the only place a failure can be observed.
///
/// Safe to write from the pipe's background reader, hence `@unchecked Sendable`
/// with an explicit lock.
final class LogSink: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        self.url = url
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            let previous = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: url, to: previous)
        }
        _ = fileManager.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }

    /// The last few lines, for the failure sheet.
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
}
