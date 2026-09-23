import Foundation

/// The engine inside this bundle, and the version it reports.
enum BundledEngine {
    static var url: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/readeck-server")
    }

    /// Asks the binary rather than trusting Info.plist.
    ///
    /// This value decides whether an upgrade is about to run migrations, so it
    /// must be the version of the engine that will actually do it. A binary
    /// swapped in without a rebuild would make the two disagree.
    static func version() -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["version"]
        process.currentDirectoryURL = Paths.supportDirectory

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

        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        // "readeck version: 0.23.4"
        return text
            .split(separator: "\n")
            .first?
            .split(separator: ":")
            .last?
            .trimmingCharacters(in: .whitespaces)
    }
}
