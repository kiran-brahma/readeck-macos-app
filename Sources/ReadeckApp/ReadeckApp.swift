import AppKit
import SwiftUI

/// Stops the engine on quit, and waits for it.
///
/// A SwiftUI app has no built-in hook for "the user quit, run async cleanup", so
/// this defers termination until the child has been reaped. Without it, quitting
/// would orphan a running server holding port 8000 and the database.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LauncherModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isServerRunning else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ReadeckApp: App {
    @State private var model = LauncherModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 460)
                .task {
                    appDelegate.model = model
                    await model.start()
                }
        }
        .defaultSize(width: 1100, height: 760)
    }
}
