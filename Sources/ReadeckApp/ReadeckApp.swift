import SwiftUI

/// Slice 1 skeleton.
///
/// Deliberately does nothing but show a window. The build pipeline has to
/// produce an ad-hoc signed bundle whose bundled engine is byte-identical to
/// upstream before any lifecycle code is worth writing.
@main
struct ReadeckApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 10) {
                Image(systemName: "book.closed")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Readeck")
                    .font(.title2.weight(.semibold))
                Text("Build skeleton. The server lifecycle lands in slice 2.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(48)
            .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 1100, height: 760)
    }
}
