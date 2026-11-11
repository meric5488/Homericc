import SwiftUI

/// Prowlarr: indexer health and a manual release search.
struct ProwlarrView: View {
    @Environment(ServiceStore.self) private var store

    var body: some View {
        if let connection = store.connection(for: .prowlarr) {
            ProwlarrContent(api: ProwlarrAPI(connection: connection))
        } else {
            NotConfiguredView(kinds: [.prowlarr])
        }
    }
}

private struct ProwlarrContent: View {
    let api: ProwlarrAPI

    @State private var indexers: Loadable<[ProwlarrIndexer]> = .idle
    @State private var failing: Set<Int> = []
    @State private var query = ""
    @State private var releases: Loadable<[ProwlarrRelease]> = .idle
    @State private var grabbed: Set<String> = []
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if query.isEmpty {
                indexerSection
            } else {
                releaseSection
            }
        }
        .navigationTitle("Prowlarr")
        .searchable(text: $query, prompt: "Chercher une release")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { if query.isEmpty { releases = .idle } }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert(runner)
    }

    @ViewBuilder private var indexerSection: some View {
        switch indexers {
        case .idle, .loading:
            ProgressView()
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .loaded(let list):
            Section {
                ForEach(list) { indexer in
                    HStack {
                        Image(systemName: statusSymbol(indexer))
                            .foregroundStyle(statusColor(indexer))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(indexer.name)
                            Text(statusLabel(indexer)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Tester") { runner.run { try await api.test(indexer); await load() } }
                            .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text("Indexeurs")
            } footer: {
                Text("\(list.filter(\.enable).count) actifs, \(failing.count) en échec.")
            }
        }
    }

    @ViewBuilder private var releaseSection: some View {
        switch releases {
        case .idle:
            Text("Valide pour chercher « \(query) » sur tous les indexeurs.").foregroundStyle(.secondary)
        case .loading:
            ProgressView()
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .loaded(let list) where list.isEmpty:
            Text("Aucun résultat.").foregroundStyle(.secondary)
        case .loaded(let list):
            ForEach(list) { release in
                VStack(alignment: .leading, spacing: 4) {
                    Text(release.title).font(.subheadline).lineLimit(3)
                    HStack {
                        Text([release.indexer, release.size.map(\.bytes), release.seeders.map { "\($0) sources" }]
                            .compactMap(\.self).joined(separator: " · "))
                        Spacer()
                        Button(grabbed.contains(release.id) ? "Envoyé" : "Télécharger") {
                            runner.run {
                                try await api.grab(release)
                                grabbed.insert(release.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(grabbed.contains(release.id))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusSymbol(_ indexer: ProwlarrIndexer) -> String {
        if !indexer.enable { return "pause.circle" }
        return failing.contains(indexer.id) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private func statusColor(_ indexer: ProwlarrIndexer) -> Color {
        if !indexer.enable { return .secondary }
        return failing.contains(indexer.id) ? .orange : .green
    }

    private func statusLabel(_ indexer: ProwlarrIndexer) -> String {
        if !indexer.enable { return "Désactivé" }
        return failing.contains(indexer.id) ? "Désactivé temporairement après des erreurs" : (indexer.protocol ?? "OK")
    }

    private func load() async {
        do {
            indexers = .loaded(try await api.indexers().sorted { $0.name < $1.name })
            failing = (try? await api.failingIndexerIDs()) ?? []
        } catch {
            indexers = .failed(error.localizedDescription)
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        releases = .loading
        do {
            releases = .loaded(try await api.search(term))
        } catch {
            releases = .failed(error.localizedDescription)
        }
    }
}
