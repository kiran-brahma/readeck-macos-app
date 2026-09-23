import Darwin
import Foundation

/// A claim on a data directory, held for as long as the process lives.
///
/// `flock` is released by the kernel when the process dies, so unlike a PID file
/// it cannot go stale and has no PID-reuse window. It answers exactly one
/// question: is another launcher already managing this data directory?
final class Ownership {
    enum Outcome {
        case acquired
        case alreadyOwned
    }

    private var descriptor: Int32 = -1

    func acquire(at url: URL) throws -> Outcome {
        // Idempotent: a restart must not treat our own lock as someone else's.
        // Two descriptors on one file are independent to flock(2), so a second
        // acquire from this process would be refused by our own lock.
        if descriptor >= 0 { return .acquired }

        let path = url.path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "could not open \(path)"]
            )
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                return .alreadyOwned
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
        }

        descriptor = fd
        return .acquired
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
