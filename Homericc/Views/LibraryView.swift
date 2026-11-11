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
    @Environment(\.dismiss) private var dismiss

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
                    StatusBadge(item: item)
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
        }
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
