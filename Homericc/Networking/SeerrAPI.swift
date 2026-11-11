import Foundation

struct SeerrRequest: Identifiable, Decodable {
    let id: Int
    let status: Int
    let type: String?
    let createdAt: String?
    let media: Media?
    let requestedBy: User?

    struct Media: Decodable {
        let tmdbId: Int?
        let tvdbId: Int?
        let mediaType: String?
        let status: Int?
    }

    struct User: Decodable {
        let displayName: String?
    }

    var isPending: Bool { status == 1 }
    var isMovie: Bool { (type ?? media?.mediaType) == "movie" }

    var statusLabel: String {
        switch status {
        case 1: "En attente"
        case 2: (media?.status == 5 ? "Disponible" : "Approuvée")
        case 3: "Refusée"
        case 4: "Échec"
        case 5: "Terminée"
        default: "Inconnu"
        }
    }

    var created: Date? { createdAt.flatMap { try? Date($0, strategy: .iso8601) } }
}

/// A TMDB result from Seerr's search, possibly already requested or available.
struct SeerrSearchResult: Identifiable, Decodable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
    let posterPath: String?
    let mediaInfo: MediaInfo?

    struct MediaInfo: Decodable {
        let status: Int?
    }

    var displayTitle: String { title ?? name ?? "Sans titre" }
    var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    var posterURL: URL? { SeerrAPI.posterURL(posterPath) }

    /// Seerr media status: 2 pending, 3 processing, 4 partially available, 5 available.
    var availability: String? {
        switch mediaInfo?.status {
        case 2: "Demandé"
        case 3: "En cours"
        case 4: "Partiel"
        case 5: "Disponible"
        default: nil
        }
    }
}

struct SeerrMediaDetails: Decodable {
    let title: String?
    let name: String?
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let nextEpisodeToAir: Episode?

    struct Episode: Decodable {
        let airDate: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let name: String?
    }
    var displayTitle: String { title ?? name ?? "Sans titre" }
}

struct SeerrAPI {
    let connection: ServiceConnection

    static func posterURL(_ path: String?) -> URL? {
        path.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") }
    }

    func requests() async throws -> [SeerrRequest] {
        struct Page: Decodable { let results: [SeerrRequest] }
        let page: Page = try await connection.get("/api/v1/request", query: [
            URLQueryItem(name: "take", value: "50"),
            URLQueryItem(name: "sort", value: "added"),
            URLQueryItem(name: "filter", value: "all"),
        ])
        return page.results
    }

    func details(for request: SeerrRequest) async throws -> SeerrMediaDetails? {
        guard let tmdbId = request.media?.tmdbId else { return nil }
        return try await connection.get("/api/v1/\(request.isMovie ? "movie" : "tv")/\(tmdbId)")
    }

    func approve(_ request: SeerrRequest) async throws {
        try await connection.perform("POST", "/api/v1/request/\(request.id)/approve")
    }

    func decline(_ request: SeerrRequest) async throws {
        try await connection.perform("POST", "/api/v1/request/\(request.id)/decline")
    }

    func search(_ query: String) async throws -> [SeerrSearchResult] {
        struct Page: Decodable { let results: [SeerrSearchResult] }
        let page: Page = try await connection.get("/api/v1/search", query: [
            URLQueryItem(name: "query", value: query),
        ])
        return page.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    func request(_ result: SeerrSearchResult) async throws {
        try await request(mediaType: result.mediaType, tmdbID: result.id)
    }

    func request(mediaType: String, tmdbID: Int) async throws {
        var body: [String: Any] = ["mediaType": mediaType, "mediaId": tmdbID]
        if mediaType == "tv" { body["seasons"] = "all" }
        try await connection.perform("POST", "/api/v1/request", json: body)
    }
}
