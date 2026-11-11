import SwiftUI

/// Search Radarr/Sonarr/Lidarr's lookup and add a result to the library.
struct AddMediaView: View {
    let api: ArrAPI
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: Loadable<[ArrItem]> = .idle
    @State private var selection: ArrItem?

    var body: some View {
        NavigationStack {
            Group {
                switch results {
                case .idle:
                    ContentUnavailableView("Ajouter dans \(api.kind.name)", systemImage: api.kind.symbol,
                                           description: Text("Cherche un titre par son nom."))
                case .loading:
                    ProgressView()
                case .failed(let message):
                    ErrorView(message: message) { await search() }
                case .loaded(let items) where items.isEmpty:
                    ContentUnavailableView.search(text: query)
                case .loaded(let items):
                    List(items) { item in
                        Button { selection = item } label: {
                            SearchResultRow(item: item)
                        }
                        .disabled(item.isInLibrary)
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 460)
            .navigationTitle("Ajouter")
            .searchable(text: $query, placement: .toolbar, prompt: api.kind == .lidarr ? "Artiste" : "Titre")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer", role: .cancel) { dismiss() }
                }
            }
            .sheet(item: $selection) { item in
                AddOptionsView(api: api, item: item) { dismiss() }
                    .frame(minWidth: 420, minHeight: 260)
            }
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        results = .loading
        do {
            results = .loaded(try await api.lookup(term))
        } catch {
            results = .failed(error.localizedDescription)
        }
    }
}

private struct SearchResultRow: View {
    let item: ArrItem

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: item.posterURL, symbol: item.kind.symbol)
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).foregroundStyle(.primary)
                if let year = item.year {
                    Text(String(year)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let overview = item.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if item.isInLibrary {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Déjà dans la bibliothèque")
            }
        }
    }
}

struct AddOptionsView: View {
    let api: ArrAPI
    let item: ArrItem
    let onAdded: () -> Void

    @State private var profiles: [ArrProfile] = []
    @State private var metadataProfiles: [ArrProfile] = []
    @State private var folders: [ArrRootFolder] = []
    @AppStorage private var profileID: Int
    @AppStorage private var metadataProfileID: Int
    @AppStorage private var folderPath: String
    @State private var searchNow = true
    @State private var loadError: String?
    @State private var runner = ActionRunner()
    @Environment(\.dismiss) private var dismissOptions

    init(api: ArrAPI, item: ArrItem, onAdded: @escaping () -> Void) {
        self.api = api
        self.item = item
        self.onAdded = onAdded
        // Remember the last choices per service.
        _profileID = AppStorage(wrappedValue: 0, "add.\(api.kind.rawValue).profile")
        _metadataProfileID = AppStorage(wrappedValue: 0, "add.\(api.kind.rawValue).metadata")
        _folderPath = AppStorage(wrappedValue: "", "add.\(api.kind.rawValue).folder")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
                Picker("Qualité", selection: $profileID) {
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }
                if api.kind == .lidarr {
                    Picker("Métadonnées", selection: $metadataProfileID) {
                        ForEach(metadataProfiles) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("Dossier", selection: $folderPath) {
                    ForEach(folders) { folder in
                        Text(folder.path).tag(folder.path)
                    }
                }
                Toggle("Lancer la recherche", isOn: $searchNow)
            }
            .formStyle(.grouped)
            .navigationTitle(item.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", role: .cancel) { dismissOptions() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        runner.run {
                            if item.isAlbum {
                                try await api.addAlbum(item, qualityProfile: profileID, metadataProfile: metadataProfileID,
                                                       rootFolder: folderPath, searchNow: searchNow)
                            } else {
                                try await api.add(item, qualityProfile: profileID,
                                                  metadataProfile: api.kind == .lidarr ? metadataProfileID : nil,
                                                  rootFolder: folderPath, searchNow: searchNow)
                            }
                            onAdded()
                        }
                    }
                    .disabled(profiles.isEmpty || folders.isEmpty || runner.isRunning)
                }
            }
            .errorAlert(runner)
            .task { await loadOptions() }
        }
    }

    private func loadOptions() async {
        do {
            profiles = try await api.qualityProfiles()
            folders = try await api.rootFolders()
            if api.kind == .lidarr { metadataProfiles = try await api.metadataProfiles() }
            if !profiles.contains(where: { $0.id == profileID }) { profileID = profiles.first?.id ?? 0 }
            if !metadataProfiles.contains(where: { $0.id == metadataProfileID }) {
                metadataProfileID = metadataProfiles.first?.id ?? 0
            }
            if !folders.contains(where: { $0.path == folderPath }) { folderPath = folders.first?.path ?? "" }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
