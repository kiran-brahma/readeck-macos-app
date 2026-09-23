import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        switch model.state {
        case .ready:
            WebView(url: Paths.baseURL)
                .ignoresSafeArea()

        case .failed(let message):
            FailureView(message: message)

        case .blocked(let message):
            // Transient: an alert is on screen and the app is about to quit.
            BlockedView(message: message)

        case .idle, .starting, .stopping:
            StartingView(status: model.statusLine)
        }
    }
}

struct StartingView: View {
    let status: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown behind the fatal alert while the app is quitting.
struct BlockedView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Readeck cannot start", systemImage: "xmark.octagon")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 380, alignment: .topLeading)
    }
}

/// Failures are shown, never swallowed: Readeck writes fatal errors to stdout,
/// so without this the app would simply look broken.
struct FailureView: View {
    @Environment(LauncherModel.self) private var model
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Readeck could not start", systemImage: "exclamationmark.triangle")
                .font(.title3.weight(.semibold))

            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(minHeight: 160)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Reveal Log") { model.revealLog() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                Button("Restart") {
                    Task { await model.restart() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 380)
    }
}
