import Foundation

/// The result of asking the port what is on it.
enum ProbeResult: Sendable, Equatable {
    /// Nothing is listening.
    case idle
    /// A Readeck server is listening, and this is its engine version.
    case readeck(version: String)
    /// Something else holds the port.
    case foreign(pid: Int32, name: String)
    /// The port answered, but not in a way we can interpret.
    case unknown(String)
}

/// Answers three questions with one unauthenticated request to `/api/info`:
/// is anything listening, is it Readeck, and which engine version is running.
///
/// Knows only a port. It does not know about the data directory, the child
/// process, or the UI.
struct EngineProbe: Sendable {
    let port: Int
    private let session: URLSession

    init(port: Int = Paths.port, timeout: TimeInterval = 2) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    private struct Info: Decodable {
        struct Version: Decodable { let canonical: String }
        let version: Version
    }

    func probe() async -> ProbeResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/info") else {
            return .unknown("could not form a probe URL")
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let info = try? JSONDecoder().decode(Info.self, from: data)
            else {
                return await foreign()
            }
            return .readeck(version: info.version.canonical)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return .idle
            case .timedOut:
                // Something accepted the connection and then did not answer.
                return await foreign()
            default:
                return .unknown(error.localizedDescription)
            }
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    private func foreign() async -> ProbeResult {
        let owner = await Task.detached { PortOwner.lookup(port: port) }.value
        guard let owner else { return .unknown("port \(port) answered, but its owner could not be identified") }
        return .foreign(pid: owner.pid, name: owner.name)
    }
}
