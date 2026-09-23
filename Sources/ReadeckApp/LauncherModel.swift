import AppKit
import Observation

/// The composition root: the only type that knows the order of operations.
///
/// Every transition is driven by an observed fact, never by elapsed time.
@MainActor
@Observable
final class LauncherModel {
    enum State: Equatable {
        case idle
        case starting
        case ready(version: String)
        /// Fatal: the port is not ours to take. Alert, then quit.
        case blocked(String)
        /// Recoverable: the engine failed after we started it. Offer a Restart.
        case failed(String)
        case stopping
    }

    private(set) var state: State = .idle
    private(set) var statusLine = ""

    private var server: ServerProcess?
    private var hasStarted = false

    private let probe = EngineProbe()
    private let ownership = Ownership()
    private let log = ServerLog(url: Paths.logFile)

    nonisolated init() {}

    var isServerRunning: Bool { server?.isRunning ?? false }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await launch()
    }

    func restart() async {
        await stop()
        hasStarted = true
        await launch()
    }

    func stop() async {
        guard let server else { return }
        state = .stopping
        await server.terminate()
        self.server = nil
    }

    // MARK: - Tools

    /// Snapshots on demand.
    ///
    /// Safe while the server is running: SQLite's backup API is consistent
    /// against a live database. The archives are left to Time Machine, since
    /// duplicating them on demand could cost gigabytes.
    func backUpNow() async {
        do {
            let destination = try await Task.detached {
                try DatabaseSnapshot.create(label: "manual")
            }.value
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Backup failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func revealBackups() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.backupsDirectory])
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile])
    }

    func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.dataDirectory])
    }

    // MARK: -

    private func launch() async {
        state = .starting
        statusLine = "Preparing…"

        do {
            try Paths.ensureDirectories()
        } catch {
            state = .failed("Could not create \(Paths.supportDirectory.path)\n\n\(error.localizedDescription)")
            return
        }

        // One launcher per data directory. The kernel releases this if we die,
        // so unlike a PID file it cannot go stale.
        do {
            if try ownership.acquire(at: Paths.lockFile) == .alreadyOwned {
                activateExistingInstance()
                NSApp.terminate(nil)
                return
            }
        } catch {
            state = .failed("Could not take the launcher lock at \(Paths.lockFile.path)\n\n\(error.localizedDescription)")
            return
        }

        // The engine's own version decides whether migrations are pending, so it
        // must be the version of the binary that will actually run them.
        statusLine = "Reading the engine version…"
        guard let bundledVersion = await Task.detached(operation: BundledEngine.version).value else {
            state = .failed("""
            The bundled Readeck engine did not report its version.

            \(BundledEngine.url.path)

            Refusing to start: without it there is no way to tell an upgrade from an ordinary start.
            """)
            return
        }

        // Probe before spawning. Two writers on one SQLite WAL database is how a
        // library gets corrupted, and nothing in Readeck prevents a second
        // server from opening the same database.
        statusLine = "Checking port \(Paths.port)…"
        switch await probe.probe() {
        case .idle:
            break

        case .readeck(let runningVersion):
            if let pid = orphanPid() {
                if runningVersion == bundledVersion {
                    // Our own engine, still running after a Force Quit. Adopt it:
                    // no downtime, and no second writer.
                    statusLine = "Adopting the running Readeck…"
                    let server = ServerProcess(engineURL: BundledEngine.url, log: log)
                    wireUnexpectedExit(server)
                    server.adopt(pid: pid)
                    self.server = server
                    markReady(version: runningVersion)
                    return
                }

                // Ours, but from a bundle that has since been replaced, so the
                // running engine is not the one we would start. Stop it and let
                // the normal path bring up the current engine.
                statusLine = "Stopping the previous engine (\(runningVersion))…"
                let stale = ServerProcess(engineURL: BundledEngine.url, log: log)
                stale.adopt(pid: pid)
                await stale.terminate()
            } else {
                block("""
                A Readeck server is already listening on \(Paths.host):\(Paths.port), running engine \(runningVersion), \
                and this app did not start it.

                Quit that server first. This app will not run a second one against the same data \
                directory, because two writers on one database is how a library gets corrupted.
                """)
                return
            }

        case .foreign(let pid, let name):
            block("""
            Port \(Paths.port) is held by another process:

            \(name) (pid \(pid))

            Free the port and start again.
            """)
            return

        case .unknown(let message):
            block("Could not probe \(Paths.host):\(Paths.port)\n\n\(message)")
            return
        }

        // Invariant I2: a snapshot must exist before a spawn that will run
        // migrations, because migrations run inside `serve` and M07/M16 rewrite
        // the archive files on disk.
        if let recorded = EngineVersionRecord.read(), recorded != bundledVersion {
            statusLine = "Backing up before upgrading \(recorded) → \(bundledVersion)…"
            do {
                _ = try await Task.detached {
                    try DatabaseSnapshot.create(label: "before-\(bundledVersion)")
                }.value
            } catch {
                state = .failed("""
                Could not back up the database before upgrading \(recorded) → \(bundledVersion).

                \(error.localizedDescription)

                Refusing to start. This upgrade runs migrations, and two of them rewrite the
                archived pages on disk.
                """)
                return
            }
        }

        statusLine = "Starting Readeck…"
        let server = ServerProcess(engineURL: BundledEngine.url, log: log)
        wireUnexpectedExit(server)
        do {
            try server.start()
        } catch {
            state = .failed("Could not start the server.\n\n\(error.localizedDescription)")
            return
        }
        self.server = server
        await waitUntilReady(server, bundledVersion: bundledVersion)
    }

    /// The recorded engine, if it is genuinely still running our binary.
    ///
    /// PIDs are reused, so liveness alone is not enough: the executable path
    /// must match the engine inside this bundle.
    private func orphanPid() -> Int32? {
        guard let record = ServerRecord.read(),
              ProcessIdentity.isAlive(record.pid),
              ProcessIdentity.executablePath(of: record.pid) == BundledEngine.url.path
        else {
            ServerRecord.clear()
            return nil
        }
        return record.pid
    }

    private func waitUntilReady(_ server: ServerProcess, bundledVersion: String) async {
        // Readiness is an observed fact — /api/info answering — not elapsed time.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return }
            if case .readeck(let version) = await probe.probe() {
                markReady(version: version)
                return
            }
            if server.isRunning == false {
                // onUnexpectedExit normally reports this; give it a moment to
                // land, then fall back to reporting it ourselves.
                try? await Task.sleep(for: .milliseconds(300))
                if case .starting = state {
                    state = .failed("""
                    The Readeck server stopped before it became ready.

                    \(log.tail())
                    """)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        state = .failed("""
        Timed out waiting for Readeck to become ready.

        \(log.tail())
        """)
    }

    /// Records the version only once the server is confirmed up, so a failed
    /// start never claims the database was migrated.
    private func markReady(version: String) {
        EngineVersionRecord.write(version)
        state = .ready(version: version)
    }

    private func wireUnexpectedExit(_ server: ServerProcess) {
        server.onUnexpectedExit = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.state = .failed("""
                The Readeck server exited unexpectedly (status \(status)).

                \(self.log.tail())
                """)
            }
        }
    }

    /// A second launch of the same app should surface the first, not exit
    /// silently and leave the user staring at nothing.
    private func activateExistingInstance() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != mine }?
            .activate(options: [.activateAllWindows])
    }

    /// The port is not ours to take. Say exactly what holds it, then quit: the
    /// app closing is the signal, and a silent exit would hide the reason.
    private func block(_ message: String) {
        state = .blocked(message)
        let alert = NSAlert()
        alert.messageText = "Readeck cannot start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
