import Foundation

struct PlexItem: Identifiable, Decodable, Hashable {
    let ratingKey: String?
    let sessionKey: String?
    let key: String?
    let type: String?
    let title: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let grandparentRatingKey: String?
    let parentRatingKey: String?
    let year: Int?
    let summary: String?
    let thumb: String?
    let art: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let parentThumb: String?
    let index: Int?
    let parentIndex: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?
    let duration: Int?
    let addedAt: Int?
    let contentRating: String?
    let studio: String?
    let audienceRating: Double?
    let originallyAvailableAt: String?
    let user: Account?
    let player: PlayerInfo?
    let media: [Media]?
    let genres: [Tag]?

    struct Account: Decodable, Hashable { let title: String? }
    struct PlayerInfo: Decodable, Hashable {
        let title: String?
        let product: String?
        let state: String?
        let local: Bool?
    }
    struct Media: Decodable, Hashable {
        let container: String?
        let videoResolution: String?
        let videoCodec: String?
        let audioCodec: String?
        let audioChannels: Int?
        let parts: [Part]?

        enum CodingKeys: String, CodingKey {
            case container, videoResolution, videoCodec, audioCodec, audioChannels
            case parts = "Part"
        }
    }
    struct Part: Decodable, Hashable {
        let key: String?
        let container: String?
    }
    struct Tag: Decodable, Hashable { let tag: String }

    enum CodingKeys: String, CodingKey {
        case ratingKey, sessionKey, key, type, title, grandparentTitle, parentTitle, grandparentRatingKey, parentRatingKey, year,
             summary, thumb, art, grandparentThumb, grandparentArt, parentThumb, index, parentIndex, viewOffset,
             viewCount, leafCount, viewedLeafCount, childCount, duration, addedAt, contentRating, studio,
             audienceRating, originallyAvailableAt
        case user = "User", player = "Player", media = "Media", genres = "Genre"
    }

    /// Lenient: a field Plex sends in an unexpected shape is dropped instead of failing the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = c.lenient(String.self, .ratingKey)
        sessionKey = c.lenient(String.self, .sessionKey)
        key = c.lenient(String.self, .key)
        type = c.lenient(String.self, .type)
        title = c.lenient(String.self, .title)
        grandparentTitle = c.lenient(String.self, .grandparentTitle)
        parentTitle = c.lenient(String.self, .parentTitle)
        grandparentRatingKey = c.lenient(String.self, .grandparentRatingKey)
        parentRatingKey = c.lenient(String.self, .parentRatingKey)
        year = c.lenient(Int.self, .year)
        summary = c.lenient(String.self, .summary)
        thumb = c.lenient(String.self, .thumb)
        art = c.lenient(String.self, .art)
        grandparentThumb = c.lenient(String.self, .grandparentThumb)
        grandparentArt = c.lenient(String.self, .grandparentArt)
        parentThumb = c.lenient(String.self, .parentThumb)
        index = c.lenient(Int.self, .index)
        parentIndex = c.lenient(Int.self, .parentIndex)
        viewOffset = c.lenient(Int.self, .viewOffset)
        viewCount = c.lenient(Int.self, .viewCount)
        leafCount = c.lenient(Int.self, .leafCount)
        viewedLeafCount = c.lenient(Int.self, .viewedLeafCount)
        childCount = c.lenient(Int.self, .childCount)
        duration = c.lenient(Int.self, .duration)
        addedAt = c.lenient(Int.self, .addedAt)
        contentRating = c.lenient(String.self, .contentRating)
        studio = c.lenient(String.self, .studio)
        audienceRating = c.lenient(Double.self, .audienceRating)
        originallyAvailableAt = c.lenient(String.self, .originallyAvailableAt)
        user = c.lenient(Account.self, .user)
        player = c.lenient(PlayerInfo.self, .player)
        media = c.lenient([Media].self, .media)
        genres = c.lenient([Tag].self, .genres)
    }

    var id: String { sessionKey ?? ratingKey ?? title ?? "" }

    /// The show for episodes, the album artist for tracks, the title otherwise.
    var headline: String { grandparentTitle ?? parentTitle ?? title ?? "Sans titre" }
    var subtitle: String? {
        switch type {
        case "episode": [episodeCode, title].compactMap(\.self).joined(separator: " · ")
        case "track": title
        default: year.map(String.init)
        }
    }
    var episodeCode: String? {
        guard type == "episode", let parentIndex, let index else { return nil }
        return String(format: "S%02dE%02d", parentIndex, index)
    }
    var artwork: String? { grandparentThumb ?? parentThumb ?? thumb }
    var backdrop: String? { art ?? grandparentArt }

    var isPlayable: Bool { type == "movie" || type == "episode" }
    var isWatched: Bool {
        if let leafCount, let viewedLeafCount { return leafCount > 0 && viewedLeafCount >= leafCount }
        return (viewCount ?? 0) > 0
    }
    var unwatchedCount: Int? {
        guard let leafCount, let viewedLeafCount else { return nil }
        return max(leafCount - viewedLeafCount, 0)
    }

    var progress: Double? {
        guard let viewOffset, let duration, duration > 0 else { return nil }
        return Double(viewOffset) / Double(duration)
    }
    var isPaused: Bool { player?.state == "paused" }

    var runtime: String? {
        guard let duration, duration > 0 else { return nil }
        return Duration.milliseconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

struct PlexSection: Identifiable, Decodable, Hashable {
    let key: String
    let title: String
    let type: String
    var id: String { key }
    var isVideo: Bool { type == "movie" || type == "show" }
}

/// What the player window needs to start: enough to rebuild the stream on its own.
struct PlexPlayback: Codable, Hashable {
    let ratingKey: String
    let title: String
    /// Milliseconds to resume from.
    let startOffset: Int
}

struct PlexAPI {
    let connection: ServiceConnection

    private struct Envelope: Decodable {
        let MediaContainer: Container
        struct Container: Decodable {
            let Metadata: [PlexItem]?
            let Directory: [PlexSection]?
            let friendlyName: String?
            let version: String?
        }
    }

    func sessions() async throws -> [PlexItem] {
        try await metadata("/status/sessions")
    }

    func recentlyAdded() async throws -> [PlexItem] {
        try await metadata("/library/recentlyAdded", query: page(size: 20))
    }

    func onDeck() async throws -> [PlexItem] {
        try await metadata("/library/onDeck", query: page(size: 20))
    }

    func sections() async throws -> [PlexSection] {
        let envelope: Envelope = try await connection.get("/library/sections")
        return envelope.MediaContainer.Directory ?? []
    }

    func items(in section: PlexSection, sort: String = "titleSort") async throws -> [PlexItem] {
        try await metadata("/library/sections/\(section.key)/all", query: [URLQueryItem(name: "sort", value: sort)])
    }

    func recentlyAdded(in section: PlexSection) async throws -> [PlexItem] {
        try await metadata("/library/sections/\(section.key)/recentlyAdded", query: page(size: 20))
    }

    func item(_ ratingKey: String) async throws -> PlexItem? {
        try await metadata("/library/metadata/\(ratingKey)").first
    }

    /// Seasons of a show, episodes of a season.
    func children(of ratingKey: String) async throws -> [PlexItem] {
        try await metadata("/library/metadata/\(ratingKey)/children")
    }

    /// Every episode of a show, whatever its seasons look like.
    func allEpisodes(of ratingKey: String) async throws -> [PlexItem] {
        try await metadata("/library/metadata/\(ratingKey)/allLeaves")
    }

    func search(_ query: String) async throws -> [PlexItem] {
        try await metadata("/search", query: [URLQueryItem(name: "query", value: query)])
    }

    // MARK: Playback

    /// A URL AVPlayer can open. MP4/MOV files play as they are; anything else (MKV…) is remuxed
    /// by Plex into HLS without re-encoding the video when the codecs allow it.
    func streamURL(for item: PlexItem, session: String) -> URL? {
        guard let ratingKey = item.ratingKey else { return nil }
        let media = item.media?.first
        let container = (media?.parts?.first?.container ?? media?.container ?? "").lowercased()
        if ["mp4", "m4v", "mov"].contains(container), let partKey = media?.parts?.first?.key {
            return connection.url(partKey, query: [URLQueryItem(name: "X-Plex-Token", value: connection.secret)])
        }
        return connection.url("/video/:/transcode/universal/start.m3u8", query: [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "maxVideoBitrate", value: "200000"),
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "location", value: connection.isUsingRemote ? "wan" : "lan"),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: session),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: "homericc-mac"),
            URLQueryItem(name: "X-Plex-Product", value: "Homericc"),
            URLQueryItem(name: "X-Plex-Platform", value: "iOS"),
            URLQueryItem(name: "X-Plex-Device", value: "Mac"),
            URLQueryItem(name: "X-Plex-Token", value: connection.secret),
        ])
    }

    /// Tells Plex where playback is, so "continue watching" works on every device.
    func reportTimeline(_ item: PlexItem, state: String, time: Int) async {
        guard let ratingKey = item.ratingKey else { return }
        try? await connection.perform("GET", "/:/timeline", query: [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(time)),
            URLQueryItem(name: "duration", value: String(item.duration ?? 0)),
        ])
    }

    func markWatched(_ item: PlexItem) async {
        guard let ratingKey = item.ratingKey else { return }
        try? await connection.perform("GET", "/:/scrobble", query: [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ])
    }

    func stopTranscode(session: String) async {
        try? await connection.perform("GET", "/video/:/transcode/universal/stop",
                                      query: [URLQueryItem(name: "session", value: session)])
    }

    // MARK: Images

    /// A resized image through Plex's transcoder; the token must ride in the URL for image loading.
    func imageURL(_ path: String?, width: Int = 300, height: Int = 450) -> URL? {
        guard let path else { return nil }
        return connection.url("/photo/:/transcode", query: [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: connection.secret),
        ])
    }

    func backdropURL(_ path: String?) -> URL? {
        imageURL(path, width: 1920, height: 1080)
    }

    // MARK: Internals

    private func metadata(_ path: String, query: [URLQueryItem] = []) async throws -> [PlexItem] {
        let envelope: Envelope = try await connection.get(path, query: query)
        return envelope.MediaContainer.Metadata ?? []
    }

    private func page(size: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
         URLQueryItem(name: "X-Plex-Container-Size", value: String(size))]
    }
}

private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
