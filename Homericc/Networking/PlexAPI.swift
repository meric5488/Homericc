import Foundation

struct PlexItem: Identifiable, Decodable {
    let ratingKey: String?
    let sessionKey: String?
    let type: String?
    let title: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let year: Int?
    let thumb: String?
    let grandparentThumb: String?
    let parentThumb: String?
    let viewOffset: Int?
    let duration: Int?
    let addedAt: Int?
    let user: Account?
    let player: PlayerInfo?

    struct Account: Decodable { let title: String? }
    struct PlayerInfo: Decodable {
        let title: String?
        let product: String?
        let state: String?
        let local: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case ratingKey, sessionKey, type, title, grandparentTitle, parentTitle, year, thumb, grandparentThumb,
             parentThumb, viewOffset, duration, addedAt
        case user = "User", player = "Player"
    }

    var id: String { sessionKey ?? ratingKey ?? title ?? "" }

    /// "Show — S01E02 title" for episodes, plain title otherwise.
    var headline: String { grandparentTitle ?? parentTitle ?? title ?? "Sans titre" }
    var subtitle: String? {
        switch type {
        case "episode", "track": title
        default: year.map(String.init)
        }
    }
    var artwork: String? { grandparentThumb ?? parentThumb ?? thumb }

    var progress: Double? {
        guard let viewOffset, let duration, duration > 0 else { return nil }
        return Double(viewOffset) / Double(duration)
    }
    var isPaused: Bool { player?.state == "paused" }
}

struct PlexAPI {
    let connection: ServiceConnection

    private struct Envelope: Decodable {
        let MediaContainer: Container
        struct Container: Decodable {
            let Metadata: [PlexItem]?
            let friendlyName: String?
            let version: String?
        }
    }

    func sessions() async throws -> [PlexItem] {
        let envelope: Envelope = try await connection.get("/status/sessions")
        return envelope.MediaContainer.Metadata ?? []
    }

    func recentlyAdded() async throws -> [PlexItem] {
        let envelope: Envelope = try await connection.get("/library/recentlyAdded", query: [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "20"),
        ])
        return envelope.MediaContainer.Metadata ?? []
    }

    /// A resized poster through Plex's transcoder; the token must ride in the URL for image loading.
    func imageURL(_ path: String?) -> URL? {
        guard let path else { return nil }
        return connection.url("/photo/:/transcode", query: [
            URLQueryItem(name: "width", value: "300"),
            URLQueryItem(name: "height", value: "450"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: connection.secret),
        ])
    }
}
