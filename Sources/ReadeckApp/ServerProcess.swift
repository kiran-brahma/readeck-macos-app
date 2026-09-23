import Foundation

/// Owns the child `readeck-server serve` process: spawning it, streaming its
/// output to the log, and stopping it.
///
/// Knows nothing about ownership, backups, or the UI.
@MainActor
final class ServerProcess {
    private(set) var isRunning = false

    private var process: Process?
    private var adoptedPid: Int32?
    private var monitor: Task<Void, Never>?
    private var isTerminating = false

    private let engineURL: URL
    private let log: ServerLog

    /// Called when the engine exits without us having asked it to.
    var onUnexpectedExit: ((Int32) -> Void)?

    init(engineURL: URL, log: ServerLog) {
        self.engineURL = engineURL
        self.log = log
    }

    var pid: Int32? {
        process?.processIdentifier ?? adoptedPid
    }

    func start() throws {
        let handle = try log.openForChild()

        let process = Process()
        process.executableURL = engineURL
        process.arguments = [
            "serve",
            "-config", Paths.configFile.path,
            "-host", Paths.host,
            "-port", String(Paths.port),
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["READECK_DATA_DIRECTORY"] = Paths.dataDirectory.path
        process.environment = environment

        // Readeck writes config.toml into its working directory, and exits 1 if
        // that directory is not writable. A Finder-launched app defaults to "/".
        process.currentDirectoryURL = Paths.supportDirectory

        // Straight to the file, not through a pipe. See ServerLog.
        process.standardOutput = handle
        process.standardError = handle

        try process.run()
        self.process = process
        self.isRunning = true
        self.isTerminating = false
        ServerRecord(pid: process.processIdentifier).write()
        watch()
    }

    /// Take responsibility for an engine that outlived a previous launcher.
    ///
    /// The caller has already established that this PID runs our bundled engine.
    func adopt(pid: Int32) {
        adoptedPid = pid
        process = nil
        isRunning = true
        isTerminating = false
        watch()
    }

    /// `SIGTERM`, then `SIGKILL`.
    ///
    /// Readeck traps SIGTERM but consumes only *one* signal, so a second polite
    /// request does nothing at all. Its own graceful shutdown is capped at five
    /// seconds, which is why the grace period here is generous but finite.
    func terminate(gracePeriod: Duration = .seconds(8)) async {
        guard let pid, isAlive() else {
            finish()
            return
        }
        isTerminating = true
        kill(pid, SIGTERM)

        if await waitForExit(gracePeriod) {
            finish()
            return
        }

        kill(pid, SIGKILL)
        _ = await waitForExit(.seconds(2))
        finish()
    }

    // MARK: -

    private func isAlive() -> Bool {
        if let process { return process.isRunning }
        if let adoptedPid { return ProcessIdentity.isAlive(adoptedPid) }
        return false
    }

    private func finish() {
        isRunning = false
        process = nil
        adoptedPid = nil
        monitor?.cancel()
        monitor = nil
        log.close()
        ServerRecord.clear()
    }

    private func watch() {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isAlive() {
                    let unexpected = !self.isTerminating
                    let status = self.process?.terminationStatus ?? 0
                    self.finish()
                    if unexpected {
                        self.onUnexpectedExit?(status)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func waitForExit(_ timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !isAlive() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !isAlive()
    }
}
