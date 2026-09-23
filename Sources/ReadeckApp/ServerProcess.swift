import Foundation

/// Owns the child `readeck-server serve` process: spawning it, streaming its
/// stdout to the log, and stopping it.
///
/// Knows nothing about ownership, backups, or the UI.
@MainActor
final class ServerProcess {
    private(set) var isRunning = false

    private var process: Process?
    private var monitor: Task<Void, Never>?
    private var isTerminating = false

    private let engineURL: URL
    private let log: LogSink

    /// Called when the engine exits without us having asked it to.
    var onUnexpectedExit: ((Int32) -> Void)?

    init(engineURL: URL, log: LogSink) {
        self.engineURL = engineURL
        self.log = log
    }

    func start() throws {
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

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let sink = log
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            sink.append(data)
        }

        try process.run()
        self.process = process
        self.isRunning = true
        self.isTerminating = false
        watch(process)
    }

    private func watch(_ process: Process) {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if !process.isRunning {
                    let status = process.terminationStatus
                    let unexpected = self?.isTerminating == false
                    self?.isRunning = false
                    if unexpected {
                        self?.onUnexpectedExit?(status)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// `SIGTERM`, then `SIGKILL`.
    ///
    /// Readeck traps SIGTERM but consumes only *one* signal, so a second polite
    /// request does nothing at all. Its own graceful shutdown is capped at five
    /// seconds, which is why the grace period here is generous but finite.
    func terminate(gracePeriod: Duration = .seconds(8)) async {
        guard let process, process.isRunning else {
            isRunning = false
            return
        }
        isTerminating = true
        let pid = process.processIdentifier
        process.terminate()

        if await waitForExit(process, gracePeriod) {
            isRunning = false
            return
        }

        kill(pid, SIGKILL)
        _ = await waitForExit(process, .seconds(2))
        isRunning = false
    }

    private func waitForExit(_ process: Process, _ timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning
    }
}
