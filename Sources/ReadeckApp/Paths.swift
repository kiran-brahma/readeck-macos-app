import Foundation

/// The filesystem layout.
///
/// Pure functions of the base directory. This type owns no policy and knows
/// nothing about servers, ports, or HTTP.
enum Paths {
    static let appName = "Readeck"
    static let host = "127.0.0.1"
    static let port = 8000
    static let baseURL = URL(string: "http://\(host):\(port)/")!

    static var supportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: appName, directoryHint: .isDirectory)
    }

    static var configFile: URL { supportDirectory.appending(path: "config.toml") }
    static var dataDirectory: URL { supportDirectory.appending(path: "data", directoryHint: .isDirectory) }
    static var backupsDirectory: URL { supportDirectory.appending(path: "backups", directoryHint: .isDirectory) }
    static var logFile: URL { supportDirectory.appending(path: "logs/server.log") }
    static var engineVersionFile: URL { supportDirectory.appending(path: "engine-version") }

    /// Held for the lifetime of the launcher, released by the kernel if it dies.
    static var lockFile: URL { supportDirectory.appending(path: ".launcher.lock") }

    /// The PID of an engine we started, so a later launch can tell our own
    /// orphan apart from a Readeck started somewhere else.
    static var serverRecordFile: URL { supportDirectory.appending(path: "server.json") }

    /// Creates the directories the launcher and the engine expect.
    ///
    /// Readeck requires a writable working directory: it writes `config.toml`
    /// there and exits 1 if it cannot, before it ever applies its environment.
    static func ensureDirectories() throws {
        for directory in [
            supportDirectory,
            dataDirectory,
            backupsDirectory,
            logFile.deletingLastPathComponent(),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
