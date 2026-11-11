import Foundation

/// A movie (Radarr), series (Sonarr) or artist (Lidarr).
/// Kept as the raw JSON too, because adding an item means posting back the lookup result.
struct ArrItem: Identifiable {
    let kind: ServiceKind
    let raw: [String: Any]

    /// The library id, nil for a search result not in the library yet.
    var libraryID: Int? { raw["id"] as? Int }
    var id: String {
        if let libraryID { return "lib-\(libraryID)" }
        return "ext-\(raw["tmdbId"] ?? raw["tvdbId"] ?? raw["foreignArtistId"] ?? title)"
    }
    var isInLibrary: Bool { libraryID != nil }

    var title: String { (raw["title"] ?? raw["artistName"]) as? String ?? "Sans titre" }
    var sortTitle: String { (raw["sortTitle"] ?? raw["sortName"]) as? String ?? title.lowercased() }
    var year: Int? { (raw["year"] as? Int).flatMap { $0 > 0 ? $0 : nil } }
    var overview: String? { (raw["overview"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var isMonitored: Bool { raw["monitored"] as? Bool ?? false }
    var status: String? { raw["status"] as? String }
    var network: String? { (raw["studio"] ?? raw["network"] ?? raw["disambiguation"]) as? String }
    var added: Date? { (raw["added"] as? String).flatMap(Self.parseDate) }

    private var statistics: [String: Any] { raw["statistics"] as? [String: Any] ?? [:] }

    var sizeOnDisk: Int64 {
        ((raw["sizeOnDisk"] ?? statistics["sizeOnDisk"]) as? NSNumber)?.int64Value ?? 0
    }

    /// 0…1, how much of the item is downloaded.
    var completion: Double {
        switch kind {
        case .radarr:
            return raw["hasFile"] as? Bool == true ? 1 : 0
        default:
            let percent = (statistics["percentOfEpisodes"] ?? statistics["percentOfTracks"]) as? Double ?? 0
            return percent / 100
        }
    }

    var completionLabel: String {
        switch kind {
        case .radarr:
            return completion >= 1 ? "Disponible" : (isMonitored ? "Manquant" : "Non surveillé")
        case .sonarr:
            let have = statistics["episodeFileCount"] as? Int ?? 0
            let total = statistics["episodeCount"] as? Int ?? 0
            return "\(have)/\(total) épisodes"
        default:
            let have = statistics["trackFileCount"] as? Int ?? 0
            let total = statistics["totalTrackCount"] as? Int ?? 0
            return "\(have)/\(total) pistes"
        }
    }

    var posterURL: URL? { imageURL(preferred: "poster") }
    var fanartURL: URL? { imageURL(preferred: "fanart") }

    private func imageURL(preferred type: String) -> URL? {
        let images = raw["images"] as? [[String: Any]] ?? []
        let image = images.first { $0["coverType"] as? String == type } ?? images.first
        // Library items carry both; search results sometimes only an absolute `url`.
        let candidates = [image?["remoteUrl"], image?["url"]].compactMap { $0 as? String }
        return candidates.first { $0.hasPrefix("http") }.flatMap(URL.init(string:))
    }

    private static func parseDate(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}

struct ArrProfile: Identifiable, Hashable, Decodable {
    let id: Int
    let name: String
}

struct ArrRootFolder: Identifiable, Hashable, Decodable {
    let id: Int
    let path: String
    let freeSpace: Int64?
}

struct ArrHealth: Identifiable, Decodable {
    let source: String?
    let type: String
    let message: String
    var id: String { message }
}

/// Radarr, Sonarr and Lidarr share the same API shape with different nouns.
struct ArrAPI {
    let connection: ServiceConnection
    var kind: ServiceKind { connection.kind }

    private var version: String { kind == .radarr || kind == .sonarr ? "v3" : "v1" }
    private var resource: String {
        switch kind {
        case .radarr: "movie"
        case .sonarr: "series"
        default: "artist"
        }
    }
    fileprivate func path(_ tail: String) -> String { "/api/\(version)/\(tail)" }

    func library() async throws -> [ArrItem] {
        try await items(path(resource))
    }

    func lookup(_ term: String) async throws -> [ArrItem] {
        try await items(path("\(resource)/lookup"), query: [URLQueryItem(name: "term", value: term)])
    }

    func qualityProfiles() async throws -> [ArrProfile] {
        try await connection.get(path("qualityprofile"))
    }

    func metadataProfiles() async throws -> [ArrProfile] {
        try await connection.get(path("metadataprofile"))
    }

    func rootFolders() async throws -> [ArrRootFolder] {
        try await connection.get(path("rootfolder"))
    }

    func health() async throws -> [ArrHealth] {
        try await connection.get(path("health"))
    }

    func add(_ item: ArrItem, qualityProfile: Int, metadataProfile: Int?, rootFolder: String,
             searchNow: Bool) async throws {
        var body = item.raw
        body["qualityProfileId"] = qualityProfile
        body["rootFolderPath"] = rootFolder
        body["monitored"] = true
        switch kind {
        case .radarr:
            body["minimumAvailability"] = "released"
            body["addOptions"] = ["searchForMovie": searchNow]
        case .sonarr:
            body["seasonFolder"] = true
            body["addOptions"] = ["monitor": "all", "searchForMissingEpisodes": searchNow]
        default:
            body["metadataProfileId"] = metadataProfile ?? 1
            body["addOptions"] = ["monitor": "all", "searchForMissingAlbums": searchNow]
        }
        try await connection.perform("POST", path(resource), json: body)
    }

    func setMonitored(_ item: ArrItem, _ monitored: Bool) async throws {
        guard let id = item.libraryID else { return }
        var body = item.raw
        body["monitored"] = monitored
        try await connection.perform("PUT", path("\(resource)/\(id)"), json: body)
    }

    func delete(_ item: ArrItem, deleteFiles: Bool) async throws {
        guard let id = item.libraryID else { return }
        try await connection.perform("DELETE", path("\(resource)/\(id)"),
                                     query: [URLQueryItem(name: "deleteFiles", value: deleteFiles ? "true" : "false")])
    }

    /// Asks the service to look for missing files right away.
    func search(_ item: ArrItem) async throws {
        guard let id = item.libraryID else { return }
        let command: [String: Any] = switch kind {
        case .radarr: ["name": "MoviesSearch", "movieIds": [id]]
        case .sonarr: ["name": "SeriesSearch", "seriesId": id]
        default: ["name": "ArtistSearch", "artistId": id]
        }
        try await connection.perform("POST", path("command"), json: command)
    }

    fileprivate func items(_ path: String, query: [URLQueryItem] = []) async throws -> [ArrItem] {
        let data = try await connection.data(path, query: query)
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.invalidResponse(kind)
        }
        return list.map { ArrItem(kind: kind, raw: $0) }
    }
}

// MARK: - Albums (Lidarr)

extension ArrItem {
    /// Lidarr album lookups return albums with their artist embedded.
    var isAlbum: Bool { kind == .lidarr && raw["albumType"] != nil }
    var artistName: String? { (raw["artist"] as? [String: Any])?["artistName"] as? String }
    var releaseYear: Int? {
        year ?? (raw["releaseDate"] as? String).flatMap { Int($0.prefix(4)) }
    }
    var tmdbID: Int? { (raw["tmdbId"] as? Int).flatMap { $0 > 0 ? $0 : nil } }
    var genres: [String] { raw["genres"] as? [String] ?? [] }
    var runtime: Int? { (raw["runtime"] as? Int).flatMap { $0 > 0 ? $0 : nil } }

    /// Year, runtime, certification: the line under the title.
    var facts: [String] {
        var facts: [String] = []
        if let year = releaseYear { facts.append(String(year)) }
        if let runtime { facts.append(Duration.seconds(runtime * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))) }
        if let certification = raw["certification"] as? String, !certification.isEmpty { facts.append(certification) }
        if kind == .sonarr, let seasons = (raw["statistics"] as? [String: Any])?["seasonCount"] as? Int {
            facts.append(seasons == 1 ? "1 saison" : "\(seasons) saisons")
        }
        return facts
    }
}

extension ArrAPI {
    func lookupAlbums(_ term: String) async throws -> [ArrItem] {
        try await items(path("album/lookup"), query: [URLQueryItem(name: "term", value: term)])
    }

    /// Adds an album, creating its artist (without monitoring the rest of the discography) when needed.
    func addAlbum(_ album: ArrItem, qualityProfile: Int, metadataProfile: Int, rootFolder: String,
                  searchNow: Bool) async throws {
        if let id = album.libraryID, id > 0 {
            try await connection.perform("PUT", path("album/monitor"), json: ["albumIds": [id], "monitored": true])
            if searchNow {
                try await connection.perform("POST", path("command"), json: ["name": "AlbumSearch", "albumIds": [id]])
            }
            return
        }
        var artist = album.raw["artist"] as? [String: Any] ?? [:]
        if (artist["id"] as? Int ?? 0) == 0 {
            artist["qualityProfileId"] = qualityProfile
            artist["metadataProfileId"] = metadataProfile
            artist["rootFolderPath"] = rootFolder
            artist["monitored"] = true
            artist["monitorNewItems"] = "none"
            artist["addOptions"] = ["monitor": "none", "searchForMissingAlbums": false]
        }
        var body = album.raw
        body["artist"] = artist
        body["monitored"] = true
        body["addOptions"] = ["searchForNewAlbum": searchNow]
        try await connection.perform("POST", path("album"), json: body)
    }

    /// Items with a release in the range: episodes (Sonarr), movies (Radarr) or albums (Lidarr).
    func calendar(from start: Date, to end: Date) async throws -> [[String: Any]] {
        let format = Date.ISO8601FormatStyle()
        let data = try await connection.data(path("calendar"), query: [
            URLQueryItem(name: "start", value: start.formatted(format)),
            URLQueryItem(name: "end", value: end.formatted(format)),
            URLQueryItem(name: "unmonitored", value: "false"),
            URLQueryItem(name: "includeSeries", value: "true"),
            URLQueryItem(name: "includeArtist", value: "true"),
        ])
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.invalidResponse(kind)
        }
        return list
    }
}

// MARK: - Episodes (Sonarr)

struct SonarrEpisode: Identifiable, Decodable {
    let id: Int
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String?
    let overview: String?
    let airDateUtc: String?
    let hasFile: Bool
    let monitored: Bool

    var airDate: Date? { airDateUtc.flatMap { try? Date($0, strategy: .iso8601) } }
    var hasAired: Bool { (airDate ?? .distantFuture) <= .now }
    var code: String { String(format: "S%02dE%02d", seasonNumber, episodeNumber) }
}

extension ArrAPI {
    func episodes(of series: ArrItem) async throws -> [SonarrEpisode] {
        guard let id = series.libraryID else { return [] }
        return try await connection.get(path("episode"), query: [URLQueryItem(name: "seriesId", value: String(id))])
    }

    func setMonitored(_ episodes: [SonarrEpisode], _ monitored: Bool) async throws {
        try await connection.perform("PUT", path("episode/monitor"),
                                     json: ["episodeIds": episodes.map(\.id), "monitored": monitored])
    }

    func search(_ episodes: [SonarrEpisode]) async throws {
        try await connection.perform("POST", path("command"), json: ["name": "EpisodeSearch", "episodeIds": episodes.map(\.id)])
    }

    func searchSeason(_ series: ArrItem, season: Int) async throws {
        guard let id = series.libraryID else { return }
        try await connection.perform("POST", path("command"),
                                     json: ["name": "SeasonSearch", "seriesId": id, "seasonNumber": season])
    }
}
