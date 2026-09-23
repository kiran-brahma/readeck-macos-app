import Darwin
import Foundation

/// Questions about a process we did not spawn.
///
/// Needed after a Force Quit: the launcher is gone, but the engine may still be
/// running, and the next launch has to decide whether that server is ours.
enum ProcessIdentity {
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Full path of the executable a PID is running, when it can be determined.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
