import SwiftUI

struct DownloadsView: View {
    @Environment(ServiceStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if let connection = store.connection(for: .qbittorrent) {
                    TorrentListView(api: QBittorrentAPI(connection: connection))
                        .id(store.revision)
                } else {
                    NotConfiguredView(kinds: [.qbittorrent])
                }
            }
            .navigationTitle("Téléchargements")
        }
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

private struct TorrentListView: View {
    let api: QBittorrentAPI

    @State private var torrents: Loadable<[Torrent]> = .idle
    @State private var transfer: TransferInfo?
    @State private var filter: TorrentFilter = .active
    @State private var runner = ActionRunner()
    @State private var pendingDelete: Torrent?

    var body: some View {
        content
            .safeAreaInset(edge: .top) {
                Picker("Afficher", selection: $filter) {
                    ForEach(TorrentFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .toolbar {
                if let transfer {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("↓ \(transfer.dl_info_speed.speed)  ↑ \(transfer.up_info_speed.speed)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            .refreshable { await load() }
            .task {
                // Live view: refresh every few seconds while on screen.
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            .errorAlert(runner)
            .confirmationDialog("Supprimer « \(pendingDelete?.name ?? "") » ?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                if let torrent = pendingDelete {
                    Button("Supprimer le torrent", role: .destructive) { delete(torrent, files: false) }
                    Button("Supprimer avec les fichiers", role: .destructive) { delete(torrent, files: true) }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch torrents {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorView(message: message) { await load() }
        case .loaded:
            let visible = visibleTorrents
            if visible.isEmpty {
                ContentUnavailableView(filter == .active ? "Aucun téléchargement en cours" : "Aucun torrent",
                                       systemImage: "arrow.down.circle")
            } else {
                List(visible) { torrent in
                    TorrentRow(torrent: torrent)
                        .swipeActions(edge: .trailing) {
                            Button("Supprimer", systemImage: "trash", role: .destructive) { pendingDelete = torrent }
                        }
                        .swipeActions(edge: .leading) {
                            if torrent.isPaused {
                                Button("Reprendre", systemImage: "play.fill") { act { try await api.resume(torrent) } }
                                    .tint(.green)
                            } else {
                                Button("Pause", systemImage: "pause.fill") { act { try await api.pause(torrent) } }
                                    .tint(.orange)
                            }
                        }
                        .contextMenu {
                            if torrent.isPaused {
                                Button("Reprendre", systemImage: "play.fill") { act { try await api.resume(torrent) } }
                            } else {
                                Button("Pause", systemImage: "pause.fill") { act { try await api.pause(torrent) } }
                            }
                            Button("Supprimer…", systemImage: "trash", role: .destructive) { pendingDelete = torrent }
                        }
                }
            }
        }
    }

    private var visibleTorrents: [Torrent] {
        let list = torrents.value ?? []
        return switch filter {
        case .all: list
        case .active: list.filter { !$0.isComplete }
        case .done: list.filter(\.isComplete)
        }
    }

    private func load() async {
        do {
            async let list = api.torrents()
            async let info = api.transfer()
            torrents = .loaded(try await list)
            transfer = try? await info
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

    private func delete(_ torrent: Torrent, files: Bool) {
        act { try await api.delete(torrent, deleteFiles: files) }
    }
}

private struct TorrentRow: View {
    let torrent: Torrent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(torrent.name)
                .font(.subheadline)
                .lineLimit(2)
            ProgressView(value: torrent.progress)
                .tint(torrent.hasError ? .red : (torrent.isPaused ? .secondary : .accentColor))
            HStack {
                Text(torrent.stateLabel)
                    .foregroundStyle(torrent.hasError ? .red : .secondary)
                Spacer()
                if torrent.dlspeed > 0 {
                    Text("↓ \(torrent.dlspeed.speed)")
                }
                if let remaining = torrent.remaining {
                    Text(remaining.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                }
                Text("\(torrent.progress.formatted(.percent.precision(.fractionLength(0)))) · \(torrent.size.bytes)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
