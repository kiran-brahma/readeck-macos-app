import Foundation

/// The PID of a server this launcher started.
///
/// `flock` proves no other launcher is running, but it cannot say which data
/// directory a listening server is using. This record is the missing half: it
/// distinguishes our own orphan, which we adopt, from a Readeck started
/// somewhere else, which we refuse to touch.
///
/// It is written when we spawn and cleared when we have stopped the engine, so
/// its presence means "a server we own may still be running".
struct ServerRecord: Codable, Sendable {
    var pid: Int32

    static var url: URL { Paths.serverRecordFile }

    static func read() -> ServerRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServerRecord.self, from: data)
    }

    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
