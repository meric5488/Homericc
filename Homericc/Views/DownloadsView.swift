import SwiftUI

struct DownloadsView: View {
    @Environment(ServiceStore.self) private var store

    var body: some View {
        Group {
            if let connection = store.connection(for: .qbittorrent) {
                TorrentTableView(api: QBittorrentAPI(connection: connection))
                    .id(store.revision)
            } else {
                NotConfiguredView(kinds: [.qbittorrent])
            }
        }
        .navigationTitle("Téléchargements")
    }
}

private enum TorrentFilter: String, CaseIterable, Identifiable {
    case active, all, done
    var id: Self { self }
    var label: String {
        switch self {
        case .active: "En cours"
        case .all: "Tous"
        case .done: "Terminés"
        }
    }
}

/// qBittorrent as a Mac table: click a column header to sort, select several rows to act on them at once.
private struct TorrentTableView: View {
    let api: QBittorrentAPI

    @State private var torrents: Loadable<[Torrent]> = .idle
    @State private var transfer: TransferInfo?
    @AppStorage("downloads.filter") private var filter: TorrentFilter = .all
    @State private var sortOrder = [KeyPathComparator(\Torrent.addedOn, order: .reverse)]
    @State private var selection = Set<Torrent.ID>()
    @State private var pendingDelete: [Torrent] = []
    @State private var runner = ActionRunner()

    var body: some View {
        content
            .toolbar { toolbar }
            .task {
                // Live view: refresh every few seconds while on screen.
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            .errorAlert(runner)
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty },
                                                                  set: { if !$0 { pendingDelete = [] } }),
                                titleVisibility: .visible) {
                let targets = pendingDelete
                Button("Supprimer les torrents", role: .destructive) { delete(targets, files: false) }
                Button("Supprimer avec les fichiers", role: .destructive) { delete(targets, files: true) }
            } message: {
                Text("Supprimer les fichiers libère de la place sur le serveur mais ne peut pas être annulé.")
            }
    }

    @ViewBuilder private var content: some View {
        switch torrents {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorView(message: message) { await load() }
        case .loaded:
            table
                .overlay {
                    if visibleTorrents.isEmpty {
                        ContentUnavailableView(filter == .active ? "Aucun téléchargement en cours" : "Aucun torrent",
                                               systemImage: "arrow.down.circle")
                    }
                }
        }
    }

    private var table: some View {
        Table(visibleTorrents, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Nom", value: \.name) { torrent in
                Text(torrent.name)
                    .lineLimit(1)
                    .help(torrent.name)
            }
            .width(min: 220, ideal: 380)

            TableColumn("Taille", value: \.size) { Text($0.size.bytes).monospacedDigit() }
                .width(min: 70, ideal: 80)

            TableColumn("Progression", value: \.progress) { torrent in
                HStack(spacing: 6) {
                    ProgressView(value: torrent.progress)
                        .tint(torrent.hasError ? .red : (torrent.isPaused ? .secondary : .accentColor))
                    Text(torrent.progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .width(min: 110, ideal: 140)

            TableColumn("État", value: \.stateLabel) { torrent in
                Text(torrent.stateLabel).foregroundStyle(torrent.hasError ? .red : .secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("↓", value: \.dlspeed) { torrent in
                Text(torrent.dlspeed > 0 ? torrent.dlspeed.speed : "").monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("↑", value: \.upspeed) { torrent in
                Text(torrent.upspeed > 0 ? torrent.upspeed.speed : "").monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Ratio", value: \.ratio) { RatioBadge(ratio: $0.ratio) }
                .width(min: 60, ideal: 70)

            TableColumn("Ajouté", value: \.addedOn) { torrent in
                Text(torrent.addedDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: Torrent.ID.self) { ids in
            let targets = torrents(for: ids)
            if !targets.isEmpty {
                Button("Reprendre", systemImage: "play.fill") { act { try await api.resume(targets) } }
                Button("Mettre en pause", systemImage: "pause.fill") { act { try await api.pause(targets) } }
                Divider()
                Button(targets.count == 1 ? "Supprimer…" : "Supprimer \(targets.count) torrents…",
                       systemImage: "trash", role: .destructive) { pendingDelete = targets }
            }
        }
        .onDeleteCommand { pendingDelete = torrents(for: selection) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Afficher", selection: $filter) {
                ForEach(TorrentFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItemGroup {
            let targets = torrents(for: selection)
            Button { act { try await api.resume(targets) } } label: {
                Label("Reprendre", systemImage: "play.fill")
            }
            .help("Reprendre la sélection")
            .disabled(targets.isEmpty)
            Button { act { try await api.pause(targets) } } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .help("Mettre la sélection en pause")
            .disabled(targets.isEmpty)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(role: .destructive) { pendingDelete = torrents(for: selection) } label: {
                Label("Supprimer", systemImage: "trash")
            }
            .help("Supprimer la sélection (⌫)")
            .disabled(selection.isEmpty)
        }
        if let transfer {
            ToolbarItem(placement: .status) {
                Text("↓ \(transfer.dl_info_speed.speed)  ↑ \(transfer.up_info_speed.speed)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Supprimer « \(pendingDelete[0].name) » ?" : "Supprimer \(pendingDelete.count) torrents ?"
    }

    private var visibleTorrents: [Torrent] {
        let list = torrents.value ?? []
        let filtered = switch filter {
        case .all: list
        case .active: list.filter { !$0.isComplete }
        case .done: list.filter(\.isComplete)
        }
        return filtered.sorted(using: sortOrder)
    }

    private func torrents(for ids: Set<Torrent.ID>) -> [Torrent] {
        (torrents.value ?? []).filter { ids.contains($0.id) }
    }

    private func load() async {
        do {
            async let list = api.torrents()
            async let info = api.transfer()
            let loaded = try await list
            torrents = .loaded(loaded)
            transfer = try? await info
            // Drop selected rows that disappeared.
            selection.formIntersection(Set(loaded.map(\.id)))
        } catch {
            if torrents.value == nil { torrents = .failed(error.localizedDescription) }
        }
    }

    private func act(_ action: @escaping () async throws -> Void) {
        runner.run {
            try await action()
            await load()
        }
    }

    private func delete(_ targets: [Torrent], files: Bool) {
        act { try await api.delete(targets, deleteFiles: files) }
        selection.subtract(targets.map(\.id))
    }
}

private struct RatioBadge: View {
    let ratio: Double

    var body: some View {
        let high = ratio >= 20
        Text(ratio.formatted(.number.precision(.fractionLength(2))))
            .monospacedDigit()
            .fontWeight(high ? .semibold : .regular)
            .foregroundStyle(high ? .green : (ratio < 1 ? .orange : .primary))
            .padding(.horizontal, high ? 6 : 0)
            .background(high ? Color.green.opacity(0.15) : .clear, in: .capsule)
            .help(high ? "Ratio supérieur à 20" : "Ratio de partage")
    }
}
