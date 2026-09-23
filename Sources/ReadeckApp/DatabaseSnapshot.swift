import Foundation

/// Consistent snapshots of the Readeck database.
///
/// Snapshots exist for one reason: `serve` runs migrations at startup, and M07
/// rewrites every archive `.zip` in place while M16 deletes and rebuilds the
/// archive tree. An engine upgrade is the one genuinely destructive event in
/// this system, so a copy must exist before a new engine touches the database.
///
/// Only the database is copied. The archives are large and mostly immutable, and
/// Time Machine already covers them.
enum DatabaseSnapshot {
    enum Failure: LocalizedError {
        case noDatabase(String)
        case sqliteFailed(Int32, String)
        case emptyResult(String)

        var errorDescription: String? {
            switch self {
            case .noDatabase(let path):
                return "there is no database at \(path)"
            case .sqliteFailed(let status, let message):
                return "sqlite3 exited \(status): \(message)"
            case .emptyResult(let path):
                return "the snapshot at \(path) was written but is empty"
            }
        }
    }

    private static let sqlite3 = "/usr/bin/sqlite3"

    @discardableResult
    static func create(
        database: URL = Paths.databaseFile,
        into directory: URL = Paths.backupsDirectory,
        label: String,
        keep: Int = 3
    ) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: database.path) else {
            throw Failure.noDatabase(database.path)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = uniqueDestination(in: directory, label: label)

        if fileManager.isExecutableFile(atPath: sqlite3) {
            try runVacuumInto(from: database, to: destination)
        } else {
            // No sqlite3 binary: copy the database and its WAL sidecars. Only
            // safe because the caller guarantees no server is writing, which
            // holds for the pre-migration case but not for an explicit backup.
            try copyBundle(from: database, to: destination)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > 0 else {
            throw Failure.emptyResult(destination.path)
        }

        prune(in: directory, keep: keep)
        return destination
    }

    /// Keeps the newest `keep` snapshots and removes the rest, sidecars included.
    static func prune(in directory: URL, keep: Int) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let snapshots = entries
            .filter { $0.lastPathComponent.hasPrefix("db-") && $0.pathExtension == "sqlite3" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
                return left > right
            }

        for stale in snapshots.dropFirst(keep) {
            try? fileManager.removeItem(at: stale)
            for suffix in ["-wal", "-shm"] {
                try? fileManager.removeItem(at: URL(fileURLWithPath: stale.path + suffix))
            }
        }
    }

    // MARK: -

    /// `VACUUM INTO` rather than `.backup`, for three reasons: `.backup` inherits
    /// the source's WAL mode and leaves a `-shm` sidecar behind, so a snapshot
    /// would be three files rather than one self-contained file; `VACUUM INTO`
    /// writes a freshly built database in the default rollback journal mode; and
    /// it refuses to overwrite an existing file, which makes clobbering a
    /// previous snapshot impossible.
    private static func runVacuumInto(from database: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlite3)
        // Quoted: the path contains a space ("Application Support").
        process.arguments = [database.path, "VACUUM INTO '\(destination.path)'"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.sqliteFailed(process.terminationStatus, message)
        }
    }

    private static func copyBundle(from database: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: database, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            try? fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
        }
    }

    /// Snapshots are timestamped to the second, and two can legitimately land in
    /// the same second — a pre-migration snapshot immediately followed by a
    /// manual one. `VACUUM INTO` refuses to overwrite, so make the name unique.
    private static func uniqueDestination(in directory: URL, label: String) -> URL {
        let base = "db-\(label)-\(timestamp())"
        var candidate = directory.appending(path: "\(base).sqlite3")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base)-\(counter).sqlite3")
            counter += 1
        }
        return candidate
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
