import SwiftUI

/// Plex as a media center: continue watching, then a shelf per library, with playback in the app.
struct PlexHomeView: View {
    @Environment(ServiceStore.self) private var store

    var body: some View {
        Group {
            if let connection = store.connection(for: .plex) {
                PlexHomeContent(api: PlexAPI(connection: connection))
                    .id(store.revision)
            } else {
                NotConfiguredView(kinds: [.plex])
            }
        }
        .navigationTitle("Plex")
    }
}

private struct PlexHomeContent: View {
    let api: PlexAPI

    @State private var onDeck: [PlexItem] = []
    @State private var shelves: [(PlexSection, [PlexItem])] = []
    @State private var state: Loadable<Void> = .idle

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ErrorView(message: message) { await load() }
            case .loaded:
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        if !onDeck.isEmpty {
                            Shelf(title: "À suivre") {
                                ForEach(onDeck) { item in
                                    NavigationLink(value: item) {
                                        ContinueCard(item: item, api: api)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        ForEach(shelves, id: \.0.id) { section, items in
                            Shelf(title: "Ajouts récents · \(section.title)", destination: section) {
                                ForEach(items) { item in
                                    NavigationLink(value: item) {
                                        PlexPosterCell(item: item, api: api)
                                            .frame(width: 140)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 28)
                }
            }
        }
        .navigationDestination(for: PlexItem.self) { item in
            PlexDetailView(api: api, item: item)
        }
        .navigationDestination(for: PlexSection.self) { section in
            PlexSectionView(api: api, section: section)
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
        }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let sections = try await api.sections().filter(\.isVideo)
            onDeck = (try? await api.onDeck()) ?? []
            var loaded: [(PlexSection, [PlexItem])] = []
            for section in sections {
                loaded.append((section, (try? await api.recentlyAdded(in: section)) ?? []))
            }
            shelves = loaded
            state = .loaded(())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// A titled horizontal row, optionally with a link to the whole library.
private struct Shelf<Content: View>: View {
    let title: String
    var destination: PlexSection?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                if let destination {
                    NavigationLink("Tout voir", value: destination)
                }
            }
            .padding(.horizontal, 28)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) { content }
                    .padding(.horizontal, 28)
            }
            .scrollIndicators(.never)
        }
    }
}

struct PlexPosterCell: View {
    let item: PlexItem
    let api: PlexAPI
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: api.imageURL(item.type == "episode" ? item.artwork : item.thumb), symbol: "play.rectangle")
                .overlay(alignment: .topTrailing) {
                    if let unwatched = item.unwatchedCount, unwatched > 0 {
                        Text("\(unwatched)")
                            .font(.caption.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.orange, in: .capsule)
                            .foregroundStyle(.white)
                            .padding(6)
                    } else if item.isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress = item.progress, progress > 0.01 {
                        ProgressView(value: progress).tint(.orange).padding(6)
                    }
                }
                .shadow(color: .black.opacity(isHovered ? 0.3 : 0), radius: 10, y: 6)
                .scaleEffect(isHovered ? 1.03 : 1)
                .animation(.snappy(duration: 0.2), value: isHovered)
                .onHover { isHovered = $0 }
            Text(item.headline).font(.callout).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wide card with the backdrop and progress, for "continue watching".
private struct ContinueCard: View {
    let item: PlexItem
    let api: PlexAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(.fill.tertiary)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: api.imageURL(item.type == "episode" ? item.thumb : item.backdrop, width: 640, height: 360)) {
                        $0.resizable().scaledToFill()
                    } placeholder: { Color.clear }
                }
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressView(value: progress).tint(.orange).padding(8)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
            Text(item.headline).font(.callout.weight(.medium)).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 280)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Library grid

struct PlexSectionView: View {
    let api: PlexAPI
    let section: PlexSection

    @State private var items: Loadable<[PlexItem]> = .idle
    @State private var query = ""
    @AppStorage("plex.sort") private var sort = "titleSort"

    var body: some View {
        Group {
            switch items {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ErrorView(message: message) { await load() }
            case .loaded(let list):
                let visible = query.isEmpty ? list : list.filter { ($0.title ?? "").localizedStandardContains(query) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 20) {
                        ForEach(visible) { item in
                            NavigationLink(value: item) { PlexPosterCell(item: item, api: api) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(section.title)
        .searchable(text: $query, placement: .toolbar, prompt: "Filtrer")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Trier par", selection: $sort) {
                        Text("Titre").tag("titleSort")
                        Text("Date d'ajout").tag("addedAt:desc")
                        Text("Date de sortie").tag("originallyAvailableAt:desc")
                        Text("Note").tag("audienceRating:desc")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Trier", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .task(id: sort) { await load() }
    }

    private func load() async {
        if items.value == nil { items = .loading }
        do {
            items = .loaded(try await api.items(in: section, sort: sort))
        } catch {
            items = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Detail

struct PlexDetailView: View {
    let api: PlexAPI
    let item: PlexItem

    @State private var full: PlexItem?
    @State private var seasons: [PlexItem] = []
    @State private var selectedSeason: String?
    @State private var episodes: [PlexItem] = []
    @State private var episodesError: String?
    @State private var episodesLoaded = false
    @Environment(\.openWindow) private var openWindow

    private var shown: PlexItem { full ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 24) {
                    if let summary = shown.summary, !summary.isEmpty {
                        Text(summary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: 820, alignment: .leading)
                    }
                    if showKey != nil {
                        episodesSection
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(shown.headline)
        .task { await load() }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: api.backdropURL(shown.backdrop)) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.fill.tertiary) }
            }
            .frame(height: 420)
            .frame(maxWidth: .infinity)
            .clipped()
            .backgroundExtensionEffect()
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                       .init(color: Color(nsColor: .windowBackgroundColor), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 24) {
                PosterImage(url: api.imageURL(shown.type == "episode" ? shown.artwork : shown.thumb), symbol: "play.rectangle")
                    .frame(width: 160)
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(shown.headline).font(.largeTitle.bold()).lineLimit(2)
                    if shown.type == "episode", let title = shown.title {
                        Text([shown.episodeCode, title].compactMap(\.self).joined(separator: " · ")).font(.title3)
                    }
                    Text(facts.joined(separator: " · "))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    if shown.isPlayable {
                        PlayButton(item: shown) { play(shown) }
                            .padding(.top, 6)
                    } else if let next = nextEpisode {
                        PlayButton(item: next, label: "Lire \(next.episodeCode ?? "")") { play(next) }
                            .padding(.top, 6)
                    }
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 32)
            .offset(y: 40)
        }
        .padding(.bottom, 40)
    }

    private var facts: [String] {
        var facts: [String] = []
        if let year = shown.year { facts.append(String(year)) }
        if let runtime = shown.runtime, shown.type != "show" { facts.append(runtime) }
        if let rating = shown.contentRating { facts.append(rating) }
        if let audience = shown.audienceRating { facts.append("★ \(audience.formatted(.number.precision(.fractionLength(1))))") }
        if let genres = shown.genres?.prefix(3), !genres.isEmpty { facts.append(genres.map(\.tag).joined(separator: ", ")) }
        if let resolution = shown.media?.first?.videoResolution {
            facts.append(resolution.allSatisfy(\.isNumber) ? "\(resolution)p" : resolution.uppercased())
        }
        return facts
    }

    /// First unwatched (or in-progress) episode of the selected season.
    private var nextEpisode: PlexItem? {
        episodes.first { ($0.viewOffset ?? 0) > 0 } ?? episodes.first { !$0.isWatched }
    }

    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Épisodes").font(.title2.bold())
                Spacer()
                if seasons.count > 1 {
                    Picker("Saison", selection: $selectedSeason) {
                        ForEach(seasons) { season in
                            Text(season.title ?? "Saison").tag(season.ratingKey)
                        }
                    }
                    .fixedSize()
                }
            }
            if let episodesError {
                Label(episodesError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if episodesLoaded && episodes.isEmpty {
                Text("Aucun épisode sur Plex pour cette saison.").foregroundStyle(.secondary)
            } else if !episodesLoaded {
                ProgressView().frame(maxWidth: .infinity)
            }
            LazyVStack(spacing: 10) {
                ForEach(episodes) { episode in
                    EpisodeRow(episode: episode, api: api) { play(episode) }
                }
            }
        }
        .task(id: selectedSeason) {
            guard let selectedSeason, let season = seasons.first(where: { $0.ratingKey == selectedSeason }) else { return }
            await loadEpisodes(of: season)
        }
    }

    private func loadEpisodes(of season: PlexItem) async {
        guard let seasonKey = season.ratingKey else { return }
        episodesError = nil
        do {
            var list = try await api.children(of: seasonKey).filter { $0.type == "episode" }
            // Some libraries file episodes oddly: fall back to the show's full episode list.
            if list.isEmpty, let showKey = season.parentRatingKey ?? self.showKey {
                list = try await api.allEpisodes(of: showKey).filter { $0.parentIndex == season.index }
            }
            episodes = list
        } catch {
            episodesError = error.localizedDescription
        }
        episodesLoaded = true
    }

    /// The show this page belongs to, whether it was opened from the show, a season or an episode.
    private var showKey: String? {
        switch shown.type {
        case "show": shown.ratingKey
        case "season": shown.parentRatingKey
        case "episode": shown.grandparentRatingKey
        default: nil
        }
    }

    private func load() async {
        guard let ratingKey = item.ratingKey else { return }
        full = try? await api.item(ratingKey)
        guard let showKey else { return }
        do {
            let children = try await api.children(of: showKey)
            seasons = children.filter { $0.type == "season" }
            if seasons.isEmpty {
                // "Hide seasons for single-season shows": the show lists its episodes directly.
                let direct = children.filter { $0.type == "episode" }
                episodes = direct.isEmpty ? try await api.allEpisodes(of: showKey) : direct
                episodesLoaded = true
                return
            }
            let preferred: String? = switch shown.type {
            case "season": shown.ratingKey
            case "episode": shown.parentRatingKey
            default: nil
            }
            selectedSeason = preferred.flatMap { key in seasons.first { $0.ratingKey == key }?.ratingKey }
                ?? (seasons.first { !$0.isWatched } ?? seasons.first)?.ratingKey
        } catch {
            episodesError = error.localizedDescription
            episodesLoaded = true
        }
    }

    private func play(_ item: PlexItem) {
        guard let ratingKey = item.ratingKey else { return }
        openWindow(value: PlexPlayback(ratingKey: ratingKey, title: item.headline, startOffset: item.viewOffset ?? 0))
    }
}

private struct PlayButton: View {
    let item: PlexItem
    var label: String?
    let action: () -> Void

    var body: some View {
        let resume = (item.viewOffset ?? 0) > 0
        Button(action: action) {
            Label(label ?? (resume ? "Reprendre" : "Lire"), systemImage: "play.fill")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .help(resume ? "Reprendre où tu t'étais arrêté" : "Lire")
    }
}

private struct EpisodeRow: View {
    let episode: PlexItem
    let api: PlexAPI
    let play: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: play) {
                Rectangle()
                    .fill(.fill.tertiary)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: api.imageURL(episode.thumb, width: 480, height: 270)) {
                            $0.resizable().scaledToFill()
                        } placeholder: { Color.clear }
                    }
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .opacity(isHovered ? 1 : 0)
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = episode.progress, progress > 0.01 {
                            ProgressView(value: progress).tint(.orange).padding(6)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 10))
                    .frame(width: 200)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityLabel("Lire \(episode.title ?? "l'épisode")")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(episode.index.map { "\($0). " } ?? "")\(episode.title ?? "Épisode")")
                        .font(.headline)
                    if episode.isWatched {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Vu")
                    }
                }
                Text([episode.runtime, episode.originallyAvailableAt].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.fill.quaternary.opacity(isHovered ? 1 : 0.6), in: .rect(cornerRadius: 14))
    }
}
