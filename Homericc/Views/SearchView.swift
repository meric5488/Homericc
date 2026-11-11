import SwiftUI

/// One search for everything: movies (Radarr), series (Sonarr), artists and albums (Lidarr).
/// Each result can be added directly, or requested through Seerr when it's configured.
struct SearchView: View {
    @Environment(ServiceStore.self) private var store

    var body: some View {
        let kinds: [ServiceKind] = [.radarr, .sonarr, .lidarr]
        Group {
            if kinds.contains(where: store.isConfigured) {
                SearchContent()
                    .id(store.revision)
            } else {
                NotConfiguredView(kinds: kinds)
            }
        }
        .navigationTitle("Rechercher")
    }
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all, movies, series, music
    var id: Self { self }
    var label: String {
        switch self {
        case .all: "Tout"
        case .movies: "Films"
        case .series: "Séries"
        case .music: "Musique"
        }
    }
}

private struct SearchGroup: Identifiable {
    let title: String
    let kind: ServiceKind
    var result: Loadable<[ArrItem]>
    var id: String { title }
}

private struct SearchContent: View {
    @Environment(ServiceStore.self) private var store

    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var groups: [SearchGroup] = []
    @State private var added: Set<String> = []
    @State private var requested: Set<String> = []
    @State private var adding: ArrItem?
    @State private var runner = ActionRunner()

    private var seerr: SeerrAPI? { store.connection(for: .seerr).map(SeerrAPI.init) }

    var body: some View {
        content
            .searchable(text: $query, placement: .toolbar, prompt: "Film, série, artiste ou album")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Catégorie", selection: $scope) {
                        ForEach(SearchScope.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            // Search as you type, after a short pause.
            .task(id: "\(query)|\(scope)") {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await search()
            }
            .sheet(item: $adding) { item in
                if let api = api(for: item.kind) {
                    AddOptionsView(api: api, item: item) {
                        added.insert(item.id)
                        adding = nil
                    }
                    .frame(minWidth: 440, minHeight: 280)
                }
            }
            .errorAlert(runner)
    }

    @ViewBuilder private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView {
                Label("Trouver quelque chose à regarder ou écouter", systemImage: "magnifyingglass")
            } description: {
                Text("Tape un titre dans le champ de recherche. Tu pourras l'ajouter à Radarr, Sonarr ou Lidarr\(seerr == nil ? "" : ", ou en faire la demande dans Seerr").")
            }
        } else {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        switch group.result {
                        case .idle, .loading:
                            ProgressView().frame(maxWidth: .infinity)
                        case .failed(let message):
                            Text(message).foregroundStyle(.red)
                        case .loaded(let items) where items.isEmpty:
                            Text("Aucun résultat").foregroundStyle(.secondary)
                        case .loaded(let items):
                            ForEach(items.prefix(12)) { item in
                                ResultRow(item: item, actions: actions(for: item))
                            }
                        }
                    }
                }
            }
        }
    }

    private func actions(for item: ArrItem) -> some View {
        HStack(spacing: 8) {
            if item.isInLibrary && !item.isAlbum {
                Label("Dans la bibliothèque", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if added.contains(item.id) {
                Label("Ajouté", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else if requested.contains(item.id) {
                Label("Demandé", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                if let seerr, item.kind != .lidarr, let tmdbID = item.tmdbID {
                    Button("Demander") {
                        runner.run {
                            try await seerr.request(mediaType: item.kind == .radarr ? "movie" : "tv", tmdbID: tmdbID)
                            requested.insert(item.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Faire la demande dans Seerr")
                }
                Button(item.isAlbum ? "Ajouter l'album…" : "Ajouter à \(item.kind.name)…") { adding = item }
                    .buttonStyle(.bordered)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
    }

    private func api(for kind: ServiceKind) -> ArrAPI? {
        store.connection(for: kind).map(ArrAPI.init)
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { groups = []; return }

        var planned: [(String, ServiceKind, (ArrAPI) async throws -> [ArrItem])] = []
        if scope == .all || scope == .movies { planned.append(("Films", .radarr, { try await $0.lookup(term) })) }
        if scope == .all || scope == .series { planned.append(("Séries", .sonarr, { try await $0.lookup(term) })) }
        if scope == .all || scope == .music {
            planned.append(("Albums", .lidarr, { try await $0.lookupAlbums(term) }))
            planned.append(("Artistes", .lidarr, { try await $0.lookup(term) }))
        }
        planned.removeAll { !store.isConfigured($0.1) }
        groups = planned.map { SearchGroup(title: $0.0, kind: $0.1, result: .loading) }

        let tasks = planned.enumerated().map { index, entry in
            Task {
                guard let api = api(for: entry.1) else { return }
                let result: Loadable<[ArrItem]>
                do { result = .loaded(try await entry.2(api)) } catch { result = .failed(error.localizedDescription) }
                // Ignore answers to an older query.
                if !Task.isCancelled, index < groups.count, groups[index].title == entry.0 {
                    groups[index].result = result
                }
            }
        }
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }
}

private struct ResultRow<Actions: View>: View {
    let item: ArrItem
    let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(url: item.posterURL, symbol: item.isAlbum ? "opticaldisc" : item.kind.symbol,
                        aspectRatio: item.kind == .lidarr ? 1 : 2 / 3)
                .frame(width: item.kind == .lidarr ? 72 : 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text([item.artistName, item.releaseYear.map(String.init), item.network]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let overview = item.overview {
                    FrenchOverview(item: item, original: overview, lineLimit: 2)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 4)
    }
}
