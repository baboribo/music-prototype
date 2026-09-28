#if DEBUG
import Foundation

/// Serves recorded, redacted responses from a directory outside the repository,
/// so parsers and UI can be exercised without an account request.
/// `manifest.json` maps request keys (see `key(_:body:)`) to file names.
struct ReplayTransport: InnerTubeTransport {
    private let directory: URL
    private let manifest: [String: String]

    init(directory path: String) throws {
        directory = URL(filePath: try ExternalFile.validate(path))
        let data = try Data(contentsOf: directory.appending(path: "manifest.json"))
        manifest = try JSONDecoder().decode([String: String].self, from: data)
    }

    static func key(_ endpoint: String, body: [String: JSON]) -> String {
        if let token = body["continuation"]?.string { return "\(endpoint):continuation:\(token)" }
        if let id = body["browseId"]?.string { return "\(endpoint):\(id)" }
        if body["videoId"] != nil || body["playlistId"] != nil {
            return "\(endpoint):\(body["playlistId"]?.string ?? ""):\(body["videoId"]?.string ?? "")"
        }
        let query = body["query"]?.string ?? ""
        return "\(endpoint):\(query):\(body["params"]?.string ?? "")"
    }

    func post(_ endpoint: String, body: [String: JSON]) async throws -> JSON {
        guard let file = manifest[Self.key(endpoint, body: body)] else { throw CatalogError.notRecorded }
        let json = try JSON(data: Data(contentsOf: directory.appending(path: file)))
        if json.loggedIn == false { throw CatalogError.signedOut }
        return json
    }
}
#endif
