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
    private var log: LogSink?
    private var hasStarted = false

    private let probe = EngineProbe()

    nonisolated init() {}

    var isServerRunning: Bool { server?.isRunning ?? false }

    private var bundledEngineURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/readeck-server")
    }

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

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile])
    }

    // MARK: -

    /// The port is not ours to take. Say exactly what is holding it, then quit:
    /// the app closing is the signal, and a silent exit would hide the reason.
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

    private func launch() async {
        state = .starting
        statusLine = "Preparing…"

        do {
            try Paths.ensureDirectories()
        } catch {
            state = .failed("Could not create \(Paths.supportDirectory.path)\n\n\(error.localizedDescription)")
            return
        }

        // Probe before spawning. Nothing may hold port 8000: two writers on one
        // SQLite WAL database is how a library gets corrupted, and nothing in
        // Readeck prevents a second server from opening the same database.
        statusLine = "Checking port \(Paths.port)…"
        switch await probe.probe() {
        case .readeck(let version):
            block("""
            A Readeck server is already listening on \(Paths.host):\(Paths.port), running engine \(version).

            Quit it first. This app will not start a second server against the same data directory.
            """)
            return

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

        case .idle:
            break
        }

        statusLine = "Starting Readeck…"
        let sink: LogSink
        do {
            sink = try LogSink(url: Paths.logFile)
        } catch {
            state = .failed("Could not open \(Paths.logFile.path)\n\n\(error.localizedDescription)")
            return
        }
        self.log = sink

        let server = ServerProcess(engineURL: bundledEngineURL, log: sink)
        server.onUnexpectedExit = { [weak self] status in
            Task { @MainActor in
                self?.state = .failed("""
                The Readeck server exited unexpectedly (status \(status)).

                \(sink.tail())
                """)
            }
        }

        do {
            try server.start()
        } catch {
            state = .failed("Could not start the server.\n\n\(error.localizedDescription)")
            return
        }
        self.server = server

        // Readiness is an observed fact — /api/info answering — not elapsed time.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return }
            if case .readeck(let version) = await probe.probe() {
                state = .ready(version: version)
                return
            }
            if server.isRunning == false {
                state = .failed("""
                The Readeck server stopped before it became ready.

                \(sink.tail())
                """)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        state = .failed("""
        Timed out waiting for Readeck to become ready.

        \(sink.tail())
        """)
    }
}
