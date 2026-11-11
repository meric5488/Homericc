import SwiftUI

struct RequestsView: View {
    @Environment(ServiceStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if let connection = store.connection(for: .seerr) {
                    SeerrView(api: SeerrAPI(connection: connection))
                        .id(store.revision)
                } else {
                    NotConfiguredView(kinds: [.seerr])
                }
            }
            .navigationTitle("Demandes")
        }
    }
}

private struct SeerrView: View {
    let api: SeerrAPI

    @State private var requests: Loadable<[SeerrRequest]> = .idle
    @State private var details: [Int: SeerrMediaDetails] = [:]
    @State private var query = ""
    @State private var results: Loadable<[SeerrSearchResult]> = .idle
    @State private var requested: Set<Int> = []
    @State private var runner = ActionRunner()

    var body: some View {
        Group {
            if query.isEmpty {
                requestList
            } else {
                searchResults
            }
        }
        .searchable(text: $query, prompt: "Demander un film ou une série")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { if query.isEmpty { results = .idle } }
        .refreshable { await load() }
        .task { if requests.value == nil { await load() } }
        .errorAlert(runner)
    }

    // MARK: Requests

    @ViewBuilder private var requestList: some View {
        switch requests {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorView(message: message) { await load() }
        case .loaded(let list) where list.isEmpty:
            ContentUnavailableView("Aucune demande", systemImage: "hand.raised",
                                   description: Text("Cherche un titre pour faire une demande."))
        case .loaded(let list):
            List {
                let pending = list.filter(\.isPending)
                if !pending.isEmpty {
                    Section("En attente") {
                        ForEach(pending) { requestRow($0) }
                    }
                }
                Section("Récentes") {
                    ForEach(list.filter { !$0.isPending }) { requestRow($0) }
                }
            }
        }
    }

    private func requestRow(_ request: SeerrRequest) -> some View {
        let detail = details[request.id]
        return HStack(spacing: 12) {
            PosterImage(url: SeerrAPI.posterURL(detail?.posterPath), symbol: request.isMovie ? "film" : "tv")
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(detail?.displayTitle ?? "…")
                Text("\(request.isMovie ? "Film" : "Série") · \(request.requestedBy?.displayName ?? "Inconnu")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(request.statusLabel)
                    .font(.caption)
                    .foregroundStyle(request.isPending ? .orange : .secondary)
            }
            Spacer(minLength: 0)
            if request.isPending {
                // Inline buttons: approving is the main job of this screen.
                HStack(spacing: 8) {
                    Button { act { try await api.decline(request) } } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Refuser")
                    Button { act { try await api.approve(request) } } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Approuver")
                }
                .buttonBorderShape(.circle)
            }
        }
        .task(id: request.id) {
            guard details[request.id] == nil else { return }
            details[request.id] = try? await api.details(for: request)
        }
    }

    // MARK: Search

    @ViewBuilder private var searchResults: some View {
        switch results {
        case .idle:
            ContentUnavailableView("Rechercher", systemImage: "magnifyingglass",
                                   description: Text("Valide pour chercher « \(query) »."))
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorView(message: message) { await search() }
        case .loaded(let list) where list.isEmpty:
            ContentUnavailableView.search(text: query)
        case .loaded(let list):
            List(list) { result in
                HStack(spacing: 12) {
                    PosterImage(url: result.posterURL, symbol: result.mediaType == "movie" ? "film" : "tv")
                        .frame(width: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.displayTitle)
                        Text([result.mediaType == "movie" ? "Film" : "Série", result.year].compactMap(\.self).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let overview = result.overview {
                            Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let availability = requested.contains(result.id) ? "Demandé" : result.availability {
                        Text(availability).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Demander") {
                            act {
                                try await api.request(result)
                                requested.insert(result.id)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        if requests.value == nil { requests = .loading }
        do {
            requests = .loaded(try await api.requests())
        } catch {
            requests = .failed(error.localizedDescription)
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        results = .loading
        do {
            results = .loaded(try await api.search(term))
        } catch {
            results = .failed(error.localizedDescription)
        }
    }

    private func act(_ action: @escaping () async throws -> Void) {
        runner.run {
            try await action()
            await load()
        }
    }
}
