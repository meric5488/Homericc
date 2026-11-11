import Foundation

/// Finds what Radarr/Sonarr manage in Plex, by TMDB/TVDB/IMDb id, so their pages can offer "Play".
/// Titles can't be trusted for this: Plex may show them in French and the *arrs in English.
@MainActor
final class PlexIndex {
    static let shared = PlexIndex()

    private var byGuid: [String: PlexItem] = [:]
    private var builtAt: Date?
    private var building: Task<Void, Never>?
    private var episodes: [String: [PlexItem]] = [:]

    /// The Plex movie or show for a Radarr movie or Sonarr series.
    func match(_ item: ArrItem, api: PlexAPI) async -> PlexItem? {
        await ensureIndex(api)
        return Self.guids(for: item).lazy.compactMap { self.byGuid[$0] }.first
    }

    /// The Plex episode for a season and episode number of a matched show.
    func episode(show: PlexItem, season: Int, number: Int, api: PlexAPI) async -> PlexItem? {
        guard let key = show.ratingKey else { return nil }
        if episodes[key] == nil {
            episodes[key] = (try? await api.allEpisodes(of: key)) ?? []
        }
        return episodes[key]?.first { $0.parentIndex == season && $0.index == number }
    }

    /// Forget everything, e.g. after new downloads.
    func invalidate() {
        byGuid = [:]
        builtAt = nil
        episodes = [:]
    }

    private func ensureIndex(_ api: PlexAPI) async {
        if let builtAt, Date.now.timeIntervalSince(builtAt) < 600 { return }
        if let building { await building.value; return }
        let task = Task {
            var map: [String: PlexItem] = [:]
            let sections = (try? await api.sections().filter(\.isVideo)) ?? []
            for section in sections {
                for item in (try? await api.items(in: section, includeGuids: true)) ?? [] {
                    for guid in item.guids ?? [] { map[guid.id] = item }
                }
            }
            byGuid = map
            builtAt = .now
            episodes = [:]
        }
        building = task
        await task.value
        building = nil
    }

    private static func guids(for item: ArrItem) -> [String] {
        var guids: [String] = []
        if let tmdb = item.tmdbID { guids.append("tmdb://\(tmdb)") }
        if let tvdb = item.raw["tvdbId"] as? Int, tvdb > 0 { guids.append("tvdb://\(tvdb)") }
        if let imdb = item.raw["imdbId"] as? String, !imdb.isEmpty { guids.append("imdb://\(imdb)") }
        return guids
    }
}
