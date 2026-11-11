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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: item.posterURL, symbol: item.kind.symbol)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    PosterImage(url: item.posterURL, symbol: item.kind.symbol)
                        .frame(width: 160)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title3.bold())
                        if let year = item.year { Text(String(year)).foregroundStyle(.secondary) }
                        if let network = item.network { Text(network).foregroundStyle(.secondary) }
                        Text(item.completionLabel).font(.subheadline)
                        if item.sizeOnDisk > 0 {
                            Text(item.sizeOnDisk.bytes).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let overview = item.overview {
                Section("Résumé") {
                    Text(overview).font(.callout)
                }
            }

            Section {
                Toggle("Surveillé", isOn: Binding(
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
                ))
                Button {
                    runner.run {
                        try await api.search(item)
                        searchStarted = true
                    }
                } label: {
                    Label(searchStarted ? "Recherche lancée" : "Rechercher maintenant", systemImage: "magnifyingglass")
                }
                .disabled(searchStarted)
            }

            Section {
                Button("Supprimer…", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(item.title)
        .errorAlert(runner)
        .confirmationDialog("Supprimer « \(item.title) » ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Retirer de \(item.kind.name)", role: .destructive) { delete(files: false) }
            Button("Retirer et effacer les fichiers", role: .destructive) { delete(files: true) }
        } message: {
            Text("Effacer les fichiers libère de la place mais ne peut pas être annulé.")
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
