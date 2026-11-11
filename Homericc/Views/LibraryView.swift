import SwiftUI

struct LibraryView: View {
    let kind: ServiceKind
    @Environment(ServiceStore.self) private var store

    var body: some View {
        Group {
            if let connection = store.connection(for: kind) {
                ArrLibraryView(api: ArrAPI(connection: connection))
                    .id(store.revision)
            } else {
                NotConfiguredView(kinds: [kind])
            }
        }
        .navigationTitle(kind.role)
    }
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case title, added, size
    var id: Self { self }
    var label: String {
        switch self {
        case .title: "Titre"
        case .added: "Date d'ajout"
        case .size: "Taille"
        }
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, missing, monitored, unmonitored
    var id: Self { self }
    var label: String {
        switch self {
        case .all: "Tout"
        case .missing: "Manquants"
        case .monitored: "Surveillés"
        case .unmonitored: "Non surveillés"
        }
    }
}

struct ArrLibraryView: View {
    let api: ArrAPI

    @State private var items: Loadable<[ArrItem]> = .idle
    @State private var query = ""
    @State private var showingAdd = false
    @AppStorage("library.sort") private var sort: LibrarySort = .title
    @AppStorage("library.filter") private var filter: LibraryFilter = .all

    var body: some View {
        content
            .searchable(text: $query, prompt: "Filtrer")
            .refreshable { await load() }
            .task { if items.value == nil { await load() } }
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Trier par", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Afficher", selection: $filter) {
                            ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Label("Trier et filtrer", systemImage: "line.3.horizontal.decrease")
                    }
                }
                ToolbarSpacer(.fixed)
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: {
                        Label("Ajouter", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd, onDismiss: { Task { await load() } }) {
                AddMediaView(api: api)
            }
            .navigationDestination(for: String.self) { id in
                if let item = items.value?.first(where: { $0.id == id }) {
                    ArrItemDetailView(api: api, item: item) { Task { await load() } }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch items {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorView(message: message) { await load() }
        case .loaded:
            let visible = visibleItems
            if visible.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 20) {
                        ForEach(visible) { item in
                            NavigationLink(value: item.id) {
                                PosterCell(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var visibleItems: [ArrItem] {
        var list = items.value ?? []
        if !query.isEmpty {
            list = list.filter { $0.title.localizedStandardContains(query) }
        }
        switch filter {
        case .all: break
        case .missing: list = list.filter { $0.isMonitored && $0.completion < 1 }
        case .monitored: list = list.filter(\.isMonitored)
        case .unmonitored: list = list.filter { !$0.isMonitored }
        }
        switch sort {
        case .title: list.sort { $0.sortTitle < $1.sortTitle }
        case .added: list.sort { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        case .size: list.sort { $0.sizeOnDisk > $1.sizeOnDisk }
        }
        return list
    }

    private func load() async {
        if items.value == nil { items = .loading }
        do {
            items = .loaded(try await api.library())
        } catch {
            items = .failed(error.localizedDescription)
        }
    }
}

private struct PosterCell: View {
    let item: ArrItem
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: item.posterURL, symbol: item.kind.symbol, aspectRatio: item.kind == .lidarr ? 1 : 2 / 3)
                .shadow(color: .black.opacity(isHovered ? 0.3 : 0), radius: 10, y: 6)
                .scaleEffect(isHovered ? 1.03 : 1)
                .animation(.snappy(duration: 0.2), value: isHovered)
                .onHover { isHovered = $0 }
                .overlay(alignment: .bottom) {
                    if item.kind != .radarr, item.completion > 0, item.completion < 1 {
                        ProgressView(value: item.completion)
                            .padding(6)
                    }
                }
                .opacity(item.isMonitored ? 1 : 0.5)
            Text(item.title)
                .font(.caption)
                .lineLimit(1)
            Text(item.completionLabel)
                .font(.caption2)
                .foregroundStyle(item.kind == .radarr && item.completion < 1 && item.isMonitored ? .orange : .secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ArrItemDetailView: View {
    let api: ArrAPI
    @State var item: ArrItem
    let onChange: () -> Void

    @State private var runner = ActionRunner()
    @State private var confirmDelete = false
    @State private var searchStarted = false
    @State private var plexItem: PlexItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    private var plex: PlexAPI? { store.connection(for: .plex).map(PlexAPI.init) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                details
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(item.title)
        .toolbar { actions }
        .errorAlert(runner)
        .confirmationDialog("Supprimer « \(item.title) » ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Retirer de \(item.kind.name)", role: .destructive) { delete(files: false) }
            Button("Retirer et effacer les fichiers", role: .destructive) { delete(files: true) }
        } message: {
            Text("Effacer les fichiers libère de la place mais ne peut pas être annulé.")
        }
    }

    /// Backdrop art that runs under the toolbar and, mirrored, under the sidebar.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: item.fanartURL ?? item.posterURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.fill.tertiary)
                }
            }
            .frame(height: 380)
            .frame(maxWidth: .infinity)
            .clipped()
            .backgroundExtensionEffect()
            // Fades the art into the window background so the title stays legible.
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                       .init(color: Color(nsColor: .windowBackgroundColor), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 24) {
                PosterImage(url: item.posterURL, symbol: item.kind.symbol, aspectRatio: item.kind == .lidarr ? 1 : 2 / 3)
                    .frame(width: 150)
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                    Text(item.facts.joined(separator: " · "))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        StatusBadge(item: item)
                        if item.kind == .radarr, let plexItem {
                            Button { play(plexItem) } label: {
                                Label((plexItem.viewOffset ?? 0) > 0 ? "Reprendre dans Plex" : "Lire dans Plex",
                                      systemImage: "play.fill")
                                    .font(.headline)
                                    .padding(.horizontal, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 32)
            .offset(y: 40)
        }
        .padding(.bottom, 40)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let overview = item.overview {
                FrenchOverview(item: item, original: overview)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                if !item.genres.isEmpty { fact("Genres", item.genres.joined(separator: ", ")) }
                if let network = item.network { fact(item.kind == .radarr ? "Studio" : "Diffusion", network) }
                fact("Fichiers", item.completionLabel)
                if item.sizeOnDisk > 0 { fact("Taille", item.sizeOnDisk.bytes) }
                if let path = item.raw["path"] as? String { fact("Dossier", path) }
            }
            .font(.callout)

            if item.kind == .sonarr {
                SonarrEpisodesSection(api: api, series: item, plexShow: plexItem, plex: plex) { play($0) }
            }
        }
        .task {
            guard let plex, item.kind != .lidarr else { return }
            plexItem = await PlexIndex.shared.match(item, api: plex)
        }
    }

    private func play(_ item: PlexItem) {
        guard let ratingKey = item.ratingKey else { return }
        navigation.playing = PlexPlayback(ratingKey: ratingKey, title: item.headline, startOffset: item.viewOffset ?? 0)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    @ToolbarContentBuilder private var actions: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: Binding(
                get: { item.isMonitored },
                set: { monitored in
                    runner.run {
                        try await api.setMonitored(item, monitored)
                        var raw = item.raw
                        raw["monitored"] = monitored
                        item = ArrItem(kind: item.kind, raw: raw)
                        onChange()
                    }
                }
            )) {
                Label("Surveillé", systemImage: item.isMonitored ? "bookmark.fill" : "bookmark")
            }
            .help(item.isMonitored ? "Ne plus surveiller" : "Surveiller")

            Button {
                runner.run {
                    try await api.search(item)
                    searchStarted = true
                }
            } label: {
                Label("Rechercher maintenant", systemImage: searchStarted ? "checkmark" : "magnifyingglass")
            }
            .help(searchStarted ? "Recherche lancée" : "Chercher les fichiers manquants")
            .disabled(searchStarted)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Supprimer", systemImage: "trash")
            }
            .help("Supprimer de \(item.kind.name)")
        }
    }

    private func delete(files: Bool) {
        runner.run {
            try await api.delete(item, deleteFiles: files)
            onChange()
            dismiss()
        }
    }
}

private struct StatusBadge: View {
    let item: ArrItem

    var body: some View {
        let (color, symbol): (Color, String) = if item.completion >= 1 {
            (.green, "checkmark.circle.fill")
        } else if item.isMonitored {
            (.orange, "clock.fill")
        } else {
            (.secondary, "bookmark.slash")
        }
        Label(item.completionLabel, systemImage: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: .capsule)
    }
}

/// Sonarr's episodes for a series, by season, with search and Plex playback.
private struct SonarrEpisodesSection: View {
    let api: ArrAPI
    let series: ArrItem
    let plexShow: PlexItem?
    let plex: PlexAPI?
    let play: (PlexItem) -> Void

    @State private var episodes: Loadable<[SonarrEpisode]> = .idle
    @State private var season: Int?
    @State private var plexEpisodes: [Int: PlexItem] = [:]
    @State private var searched: Set<Int> = []
    @State private var runner = ActionRunner()

    private var seasons: [Int] {
        Array(Set((episodes.value ?? []).map(\.seasonNumber))).sorted { a, b in
            // Specials (season 0) last.
            a == 0 ? false : (b == 0 ? true : a < b)
        }
    }

    private var shown: [SonarrEpisode] {
        (episodes.value ?? []).filter { $0.seasonNumber == season }.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Épisodes").font(.title2.bold())
                Spacer()
                if let season {
                    Button {
                        runner.run {
                            try await api.searchSeason(series, season: season)
                            searched.formUnion(shown.filter { !$0.hasFile }.map(\.id))
                        }
                    } label: {
                        Label("Rechercher la saison", systemImage: "magnifyingglass")
                    }
                    .disabled(shown.allSatisfy(\.hasFile))
                }
                if seasons.count > 1 {
                    Picker("Saison", selection: $season) {
                        ForEach(seasons, id: \.self) { number in
                            Text(number == 0 ? "Épisodes spéciaux" : "Saison \(number)").tag(Int?.some(number))
                        }
                    }
                    .fixedSize()
                }
            }

            switch episodes {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .loaded:
                VStack(spacing: 0) {
                    ForEach(shown) { episode in
                        SonarrEpisodeRow(episode: episode, plexEpisode: plexEpisodes[episode.id],
                                         searched: searched.contains(episode.id), play: play) {
                            runner.run {
                                try await api.search([episode])
                                searched.insert(episode.id)
                            }
                        } toggleMonitored: {
                            runner.run {
                                try await api.setMonitored([episode], !episode.monitored)
                                await load()
                            }
                        }
                        if episode.id != shown.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14))
            }
        }
        .errorAlert(runner)
        .task { await load() }
        .task(id: "\(season ?? -1)-\(plexShow?.ratingKey ?? "")") { await matchPlex() }
    }

    private func load() async {
        do {
            let list = try await api.episodes(of: series)
            episodes = .loaded(list)
            if season == nil {
                // Start on the latest season with aired episodes.
                let aired = Set(list.filter(\.hasAired).map(\.seasonNumber)).filter { $0 > 0 }
                season = aired.max() ?? seasons.first
            }
        } catch {
            episodes = .failed(error.localizedDescription)
        }
    }

    private func matchPlex() async {
        guard let plexShow, let plex else { return }
        for episode in shown where episode.hasFile && plexEpisodes[episode.id] == nil {
            plexEpisodes[episode.id] = await PlexIndex.shared.episode(show: plexShow, season: episode.seasonNumber,
                                                                      number: episode.episodeNumber, api: plex)
        }
    }
}

private struct SonarrEpisodeRow: View {
    let episode: SonarrEpisode
    let plexEpisode: PlexItem?
    let searched: Bool
    let play: (PlexItem) -> Void
    let search: () -> Void
    let toggleMonitored: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(episode.episodeNumber)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title ?? "Épisode \(episode.episodeNumber)").lineLimit(1)
                if let date = episode.airDate {
                    Text(date.formatted(date: .long, time: episode.hasAired ? .omitted : .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            status
            if let plexEpisode {
                Button { play(plexEpisode) } label: {
                    Label("Lire", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .help((plexEpisode.viewOffset ?? 0) > 0 ? "Reprendre dans Plex" : "Lire dans Plex")
            } else if !episode.hasFile && episode.hasAired {
                Button(action: search) {
                    Label(searched ? "Recherche lancée" : "Rechercher", systemImage: searched ? "checkmark" : "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(searched)
                .help(searched ? "Recherche lancée" : "Rechercher cet épisode")
            }
            Button(action: toggleMonitored) {
                Image(systemName: episode.monitored ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(episode.monitored ? Color.accentColor : .secondary)
            .help(episode.monitored ? "Ne plus surveiller" : "Surveiller")
            .accessibilityLabel(episode.monitored ? "Ne plus surveiller" : "Surveiller")
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var status: some View {
        if episode.hasFile {
            Label("Téléchargé", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .labelStyle(.iconOnly).help("Téléchargé")
        } else if !episode.hasAired {
            Label("À venir", systemImage: "clock").foregroundStyle(.secondary)
                .labelStyle(.iconOnly).help("Pas encore diffusé")
        } else if episode.monitored {
            Label("Manquant", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                .labelStyle(.iconOnly).help("Manquant")
        }
    }
}
