import SwiftUI

struct DashboardView: View {
    @Environment(ServiceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    @State private var statuses: [ServiceKind: Result<ServiceStatus, Error>] = [:]
    @State private var sessions: [PlexItem] = []
    @State private var recent: [PlexItem] = []
    @State private var torrents: [Torrent] = []
    @State private var transfer: TransferInfo?
    @State private var pendingRequests = 0
    @State private var warnings: [(ServiceKind, ArrHealth)] = []

    private var configured: [ServiceKind] { ServiceKind.allCases.filter(store.isConfigured) }
    private var plex: PlexAPI? { store.connection(for: .plex).map(PlexAPI.init) }

    var body: some View {
        Group {
                if configured.isEmpty {
                    ContentUnavailableView {
                        Label("Bienvenue dans Homericc", systemImage: "house")
                    } description: {
                        Text("Ajoute tes serveurs Radarr, Sonarr, Plex, qBittorrent… pour tout piloter d'ici, chez toi comme à l'extérieur.")
                    } actions: {
                        Button("Configurer mes services…") { openSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    dashboard
                }
            }
        .navigationTitle("Accueil")
    }

    private var dashboard: some View {
        List {
            Section("Services") {
                ForEach(configured) { kind in
                    StatusRow(kind: kind, status: statuses[kind])
                }
            }

            if !sessions.isEmpty {
                Section("En lecture sur Plex") {
                    ForEach(sessions) { item in
                        NowPlayingRow(item: item, imageURL: plex?.imageURL(item.artwork))
                    }
                }
            }

            if store.isConfigured(.qbittorrent) {
                Section("Téléchargements") {
                    Button { navigation.selection = .downloads } label: {
                        LabeledContent {
                            if let transfer {
                                Text("↓ \(transfer.dl_info_speed.speed)").monospacedDigit()
                            }
                        } label: {
                            let active = torrents.filter { !$0.isComplete }.count
                            Label(active == 0 ? "Rien en cours" : "\(active) en cours", systemImage: "arrow.down.circle")
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            if store.isConfigured(.seerr) {
                Section("Demandes") {
                    Button { navigation.selection = .requests } label: {
                        Label(pendingRequests == 0 ? "Aucune demande en attente" : "\(pendingRequests) en attente d'approbation",
                              systemImage: "hand.raised")
                    }
                    .foregroundStyle(pendingRequests == 0 ? .secondary : .primary)
                }
            }

            if !warnings.isEmpty {
                Section("Alertes") {
                    ForEach(warnings, id: \.1.id) { kind, health in
                        Label {
                            VStack(alignment: .leading) {
                                Text(kind.name).font(.caption).foregroundStyle(.secondary)
                                Text(health.message).font(.subheadline)
                            }
                        } icon: {
                            Image(systemName: health.type == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(health.type == "error" ? .red : .orange)
                        }
                    }
                }
            }

            if !recent.isEmpty {
                Section("Ajouts récents sur Plex") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(recent) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    PosterImage(url: plex?.imageURL(item.artwork), symbol: "play.rectangle")
                                    Text(item.headline).font(.caption).lineLimit(1)
                                }
                                .frame(width: 96)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
        }
        .refreshable { await load() }
        .task(id: store.revision) { await load() }
    }

    private func load() async {
        // Each service loads on its own so a slow one doesn't hold up the others.
        var tasks: [Task<Void, Never>] = []
        for kind in configured {
            guard let connection = store.connection(for: kind) else { continue }
            tasks.append(Task {
                do { statuses[kind] = .success(try await ServiceStatus.check(connection)) } catch { statuses[kind] = .failure(error) }
            })
        }
        if let plex {
            tasks.append(Task {
                sessions = (try? await plex.sessions()) ?? []
                recent = (try? await plex.recentlyAdded()) ?? []
            })
        }
        if let connection = store.connection(for: .qbittorrent) {
            tasks.append(Task {
                let api = QBittorrentAPI(connection: connection)
                torrents = (try? await api.torrents()) ?? []
                transfer = try? await api.transfer()
            })
        }
        if let connection = store.connection(for: .seerr) {
            tasks.append(Task {
                let requests = (try? await SeerrAPI(connection: connection).requests()) ?? []
                pendingRequests = requests.filter { $0.isPending }.count
            })
        }
        tasks.append(Task {
            var found: [(ServiceKind, ArrHealth)] = []
            for kind in [ServiceKind.radarr, .sonarr, .lidarr] {
                guard let connection = store.connection(for: kind) else { continue }
                let health = (try? await ArrAPI(connection: connection).health()) ?? []
                found += health.filter { $0.type != "notice" }.map { (kind, $0) }
            }
            warnings = found
        })
        for task in tasks { await task.value }
    }
}

private struct StatusRow: View {
    let kind: ServiceKind
    let status: Result<ServiceStatus, Error>?

    var body: some View {
        HStack {
            Label(kind.name, systemImage: kind.symbol)
            Spacer()
            switch status {
            case nil:
                ProgressView()
            case .success(let status):
                Text([status.version, status.isRemote ? "distant" : nil].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("En ligne")
            case .failure(let error):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(error.localizedDescription)
            }
        }
    }
}

private struct NowPlayingRow: View {
    let item: PlexItem
    let imageURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: imageURL, symbol: "play.rectangle")
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.headline).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text([item.user?.title, item.player?.title ?? item.player?.product].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = item.progress {
                    ProgressView(value: progress)
                }
            }
            if item.isPaused {
                Image(systemName: "pause.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("En pause")
            }
        }
    }
}
