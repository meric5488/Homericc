import SwiftUI

/// A release on a given day: an episode, a movie release, an album, or a pending Seerr request.
struct CalendarEvent: Identifiable {
    let id: String
    let date: Date
    let source: ServiceKind
    let title: String
    let detail: String
    let posterURL: URL?
    let isDownloaded: Bool
    /// Date-only events (movies, albums) have no meaningful time.
    let hasTime: Bool
    /// "movie-tmdb-…", "tv-tvdb-…": the same title across Radarr/Sonarr and Seerr, whatever its language.
    var mediaKeys: Set<String> = []
}

private func mediaKeys(_ type: String, tmdb: Any?, tvdb: Any? = nil) -> Set<String> {
    var keys: Set<String> = []
    if let id = tmdb as? Int, id > 0 { keys.insert("\(type)-tmdb-\(id)") }
    if let id = tvdb as? Int, id > 0 { keys.insert("\(type)-tvdb-\(id)") }
    return keys
}

private enum CalendarSource: String, CaseIterable, Identifiable {
    case sonarr, radarr, lidarr, seerr
    var id: Self { self }
    var kind: ServiceKind { ServiceKind(rawValue: rawValue)! }
}

struct CalendarView: View {
    @Environment(ServiceStore.self) private var store

    var body: some View {
        let kinds: [ServiceKind] = [.sonarr, .radarr, .lidarr, .seerr]
        Group {
            if kinds.contains(where: store.isConfigured) {
                CalendarContent()
                    .id(store.revision)
            } else {
                NotConfiguredView(kinds: kinds)
            }
        }
        .navigationTitle("Calendrier")
    }
}

private struct CalendarContent: View {
    @Environment(ServiceStore.self) private var store

    @State private var events: Loadable<[CalendarEvent]> = .idle
    @State private var failures: [String] = []
    @AppStorage("calendar.showPast") private var showPast = false
    @AppStorage("calendar.hidden") private var hiddenSources = ""

    private let calendar = Calendar.current

    var body: some View {
        content
            .toolbar {
                ToolbarItem {
                    Menu {
                        Toggle("Afficher les 7 derniers jours", isOn: $showPast)
                        Section("Sources") {
                            ForEach(CalendarSource.allCases.filter { store.isConfigured($0.kind) }) { source in
                                Toggle(source.kind.name, isOn: Binding(
                                    get: { !hiddenSources.contains(source.rawValue) },
                                    set: { visible in
                                        var hidden = Set(hiddenSources.split(separator: ",").map(String.init))
                                        if visible { hidden.remove(source.rawValue) } else { hidden.insert(source.rawValue) }
                                        hiddenSources = hidden.sorted().joined(separator: ",")
                                    }
                                ))
                            }
                        }
                    } label: {
                        Label("Filtrer", systemImage: "line.3.horizontal.decrease")
                    }
                }
                ToolbarItem {
                    Button { Task { await load() } } label: {
                        Label("Actualiser", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r")
                }
            }
            .task(id: showPast) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch events {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorView(message: message) { await load() }
        case .loaded:
            let days = groupedByDay
            if days.isEmpty {
                ContentUnavailableView("Rien de prévu", systemImage: "calendar",
                                       description: Text("Aucune sortie dans les 60 prochains jours pour ce que tu suis."))
            } else {
                List {
                    if !failures.isEmpty {
                        Section {
                            ForEach(failures, id: \.self) { Text($0).foregroundStyle(.red) }
                        }
                    }
                    ForEach(days, id: \.0) { day, items in
                        Section {
                            ForEach(items) { EventRow(event: $0) }
                        } header: {
                            DayHeader(day: day)
                        }
                    }
                }
            }
        }
    }

    private var groupedByDay: [(Date, [CalendarEvent])] {
        let hidden = Set(hiddenSources.split(separator: ",").map(String.init))
        let visible = (events.value ?? []).filter { !hidden.contains($0.source.rawValue) }
        let byDay = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted().map { day in
            (day, byDay[day]!.sorted { ($0.date, $0.title) < ($1.date, $1.title) })
        }
    }

    // MARK: Loading

    private func load() async {
        if events.value == nil { events = .loading }
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: showPast ? -7 : 0, to: today)!
        let end = calendar.date(byAdding: .day, value: 60, to: today)!

        var collected: [CalendarEvent] = []
        var errors: [String] = []
        let tasks: [Task<Result<[CalendarEvent], Error>, Never>] = [
            ServiceKind.sonarr, .radarr, .lidarr, .seerr,
        ].compactMap { kind in
            guard let connection = store.connection(for: kind) else { return nil }
            return Task {
                do {
                    return .success(try await fetch(kind, connection, start, end))
                } catch {
                    return .failure(error)
                }
            }
        }
        for task in tasks {
            switch await task.value {
            case .success(let list): collected += list
            case .failure(let error): errors.append(error.localizedDescription)
            }
        }
        // Seerr requests already sent to Radarr/Sonarr show up there; keep only the extra ones.
        let known = collected.filter { $0.source != .seerr }.reduce(into: Set<String>()) { $0.formUnion($1.mediaKeys) }
        let knownTitles = Set(collected.filter { $0.source != .seerr }.map { $0.title.lowercased() })
        collected.removeAll { event in
            event.source == .seerr && (!event.mediaKeys.isDisjoint(with: known) || knownTitles.contains(event.title.lowercased()))
        }

        failures = errors
        events = .loaded(collected.filter { $0.date >= start && $0.date < end })
    }

    private func fetch(_ kind: ServiceKind, _ connection: ServiceConnection, _ start: Date, _ end: Date) async throws -> [CalendarEvent] {
        if kind == .seerr {
            return try await seerrEvents(SeerrAPI(connection: connection))
        }
        let list = try await ArrAPI(connection: connection).calendar(from: start, to: end)
        return switch kind {
        case .sonarr: list.compactMap(Self.episode)
        case .radarr: list.flatMap(Self.movieReleases)
        default: list.compactMap(Self.album)
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = try? Date(string, strategy: .iso8601) { return date }
        // Date-only strings ("2026-11-20") are local calendar days.
        return try? Date(String(string.prefix(10)), strategy: Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    private static func poster(_ images: Any?) -> URL? {
        ArrItem(kind: .sonarr, raw: ["images": images ?? []]).posterURL
    }

    private static func episode(_ raw: [String: Any]) -> CalendarEvent? {
        guard let date = date(raw["airDateUtc"]) else { return nil }
        let series = raw["series"] as? [String: Any] ?? [:]
        let season = raw["seasonNumber"] as? Int ?? 0
        let number = raw["episodeNumber"] as? Int ?? 0
        let code = String(format: "S%02dE%02d", season, number)
        let title = raw["title"] as? String
        var event = CalendarEvent(
            id: "sonarr-\(raw["id"] ?? code)", date: date, source: .sonarr,
            title: series["title"] as? String ?? "Série",
            detail: [code, title].compactMap(\.self).joined(separator: " · "),
            posterURL: poster(series["images"]), isDownloaded: raw["hasFile"] as? Bool ?? false, hasTime: true)
        event.mediaKeys = mediaKeys("tv", tmdb: series["tmdbId"], tvdb: series["tvdbId"])
        return event
    }

    /// One event per day: a digital and physical release on the same date are merged.
    private static func movieReleases(_ raw: [String: Any]) -> [CalendarEvent] {
        let kinds = [("inCinemas", "Sortie en salle"), ("digitalRelease", "Sortie numérique"), ("physicalRelease", "Sortie DVD/Blu-ray")]
        let dated = kinds.compactMap { key, label in date(raw[key]).map { (Calendar.current.startOfDay(for: $0), label) } }
        let byDay = Dictionary(grouping: dated, by: \.0)
        return byDay.keys.sorted().map { day in
            var event = CalendarEvent(
                id: "radarr-\(raw["id"] ?? "")-\(day.timeIntervalSince1970)", date: day, source: .radarr,
                title: raw["title"] as? String ?? "Film",
                detail: byDay[day]!.map(\.1).formatted(.list(type: .and)),
                posterURL: poster(raw["images"]), isDownloaded: raw["hasFile"] as? Bool ?? false, hasTime: false)
            event.mediaKeys = mediaKeys("movie", tmdb: raw["tmdbId"])
            return event
        }
    }

    private static func album(_ raw: [String: Any]) -> CalendarEvent? {
        guard let date = date(raw["releaseDate"]) else { return nil }
        let artist = raw["artist"] as? [String: Any] ?? [:]
        let stats = raw["statistics"] as? [String: Any] ?? [:]
        return CalendarEvent(
            id: "lidarr-\(raw["id"] ?? "")", date: date, source: .lidarr,
            title: raw["title"] as? String ?? "Album",
            detail: ["Album", artist["artistName"] as? String].compactMap(\.self).joined(separator: " · "),
            posterURL: poster(raw["images"]), isDownloaded: (stats["percentOfTracks"] as? Double ?? 0) >= 100,
            hasTime: false)
    }

    /// Requests waiting for approval aren't in Radarr/Sonarr yet: date them from TMDB via Seerr.
    private func seerrEvents(_ api: SeerrAPI) async throws -> [CalendarEvent] {
        let requests = try await api.requests().filter { $0.status == 1 || $0.status == 2 }
        var result: [CalendarEvent] = []
        var seen: Set<String> = []
        var unique: [SeerrRequest] = []
        for request in requests {
            let keys = mediaKeys(request.isMovie ? "movie" : "tv", tmdb: request.media?.tmdbId, tvdb: request.media?.tvdbId)
            // Several requests (per season, 4K…) can target the same title.
            guard keys.isEmpty || seen.isDisjoint(with: keys) else { continue }
            seen.formUnion(keys)
            unique.append(request)
        }
        // Fetch every title's dates at once rather than one after the other.
        let lookups = unique.map { request in Task { (request, try? await api.details(for: request)) } }
        for lookup in lookups {
            let (request, fetched) = await lookup.value
            guard let details = fetched else { continue }
            let poster = SeerrAPI.posterURL(details.posterPath)
            let status = request.isPending ? "Demande en attente" : "Demande approuvée"
            if request.isMovie, let date = Self.date(details.releaseDate) {
                result.append(CalendarEvent(id: "seerr-\(request.id)", date: date, source: .seerr,
                                            title: details.displayTitle, detail: "\(status) · Sortie",
                                            posterURL: poster, isDownloaded: false, hasTime: false))
            } else if let next = details.nextEpisodeToAir, let date = Self.date(next.airDate) {
                let code = String(format: "S%02dE%02d", next.seasonNumber ?? 0, next.episodeNumber ?? 0)
                result.append(CalendarEvent(id: "seerr-\(request.id)", date: date, source: .seerr,
                                            title: details.displayTitle, detail: "\(status) · \(code)",
                                            posterURL: poster, isDownloaded: false, hasTime: false))
            } else if let date = Self.date(details.firstAirDate) {
                result.append(CalendarEvent(id: "seerr-\(request.id)", date: date, source: .seerr,
                                            title: details.displayTitle, detail: "\(status) · Première diffusion",
                                            posterURL: poster, isDownloaded: false, hasTime: false))
            }
        }
        return result.map { event in
            var event = event
            let request = requests.first { "seerr-\($0.id)" == event.id }
            event.mediaKeys = mediaKeys(request?.isMovie == true ? "movie" : "tv",
                                        tmdb: request?.media?.tmdbId, tvdb: request?.media?.tvdbId)
            return event
        }
    }
}

private struct DayHeader: View {
    let day: Date

    var body: some View {
        let calendar = Calendar.current
        let label: String = if calendar.isDateInToday(day) {
            "Aujourd'hui"
        } else if calendar.isDateInTomorrow(day) {
            "Demain"
        } else if calendar.isDateInYesterday(day) {
            "Hier"
        } else {
            day.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized
        }
        HStack {
            Text(label)
            if label != day.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized {
                Text(day.formatted(.dateTime.day().month(.wide))).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: event.posterURL, symbol: event.source.symbol)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.headline)
                Text(event.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if event.isDownloaded {
                Label("Téléchargé", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("Téléchargé")
            }
            if event.hasTime {
                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Label(event.source.name, systemImage: event.source.symbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .help(event.source.name)
        }
        .padding(.vertical, 2)
    }
}
