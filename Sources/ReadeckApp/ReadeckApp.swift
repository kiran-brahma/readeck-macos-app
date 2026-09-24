import AppKit
import SwiftUI

/// Owns the app's lifetime independently of any window.
///
/// The model lives here rather than in a view because the server must keep
/// running when the window goes away — that is the point of closing the window,
/// so the browser extension can still reach Readeck. A view's `.task` would be
/// cancelled the moment the window disappeared, which could also strand a
/// half-finished startup with no way to retry it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel()

    /// SwiftUI's `openWindow`, captured from the view hierarchy so an AppKit
    /// reopen can restore a window that has been hidden.
    var openWindow: OpenWindowAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isServerRunning else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Closing the window must not stop the app.
    ///
    /// Readeck keeps serving while the app runs, so a closed window with a live
    /// server is the intended state: the browser extension can still reach it.
    /// Letting the default apply terminates the app on the last window close,
    /// which stops the server and makes the app unreachable.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A Dock click after the window was closed.
    ///
    /// Without this the app is alive but unreachable, which is indistinguishable
    /// from a crash — the window is hidden, and nothing else brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func showMainWindow() {
        NSApp.activate()
        // Measured: closing a SwiftUI window hides it rather than destroying it,
        // and `openWindow(id:)` flips it back to visible. So this is the primary
        // mechanism, not a fallback.
        if let openWindow {
            openWindow(id: ReadeckApp.mainWindowID)
        } else if let window = NSApp.windows.first(where: { !$0.title.isEmpty }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct ReadeckApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single `Window`, not a `WindowGroup`: this app has exactly one thing
        // to show, and a singleton window can be reopened by identifier.
        Window("Readeck", id: Self.mainWindowID) {
            ContentView()
                .environment(appDelegate.model)
                .frame(minWidth: 640, minHeight: 460)
                .background(WindowOpenerRegistrar { appDelegate.openWindow = $0 })
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            // Closing the window is no longer a dead end.
            CommandGroup(after: .windowList) {
                Divider()
                Button("Show Readeck Window") { appDelegate.showMainWindow() }
                    .keyboardShortcut("1", modifiers: .command)
            }

            CommandMenu("Tools") {
                Button("Back Up Now") {
                    Task { await appDelegate.model.backUpNow() }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Reveal Backups in Finder") { appDelegate.model.revealBackups() }
                Button("Reveal Log") { appDelegate.model.revealLog() }

                Divider()

                Button("Open Data Folder") { appDelegate.model.revealData() }
            }
        }
    }
}

/// Captures SwiftUI's `openWindow` action, which is only reachable from inside
/// the view hierarchy.
private struct WindowOpenerRegistrar: View {
    @Environment(\.openWindow) private var openWindow
    let register: (OpenWindowAction) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { register(openWindow) }
    }
}
