import Foundation

/// The engine version that last opened the database.
///
/// This is what makes an upgrade distinguishable from an ordinary start. It is
/// written only once the server is confirmed ready, so a failed start does not
/// claim the database was migrated.
enum EngineVersionRecord {
    static func read() -> String? {
        guard let text = try? String(contentsOf: Paths.engineVersionFile, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func write(_ version: String) {
        try? version.write(to: Paths.engineVersionFile, atomically: true, encoding: .utf8)
    }
}
