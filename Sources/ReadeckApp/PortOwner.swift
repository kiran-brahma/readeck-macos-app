import Foundation

/// Identifies whatever holds a TCP port, so a refusal can name it.
enum PortOwner {
    struct Owner: Sendable {
        let pid: Int32
        let name: String
    }

    static func lookup(port: Int) -> Owner? {
        guard let listing = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]),
              let firstLine = listing.split(separator: "\n").first,
              let pid = Int32(firstLine.trimmingCharacters(in: .whitespaces))
        else {
            return nil
        }

        let command = run("/bin/ps", ["-p", "\(pid)", "-o", "comm="])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = command.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
        return Owner(pid: pid, name: name)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
