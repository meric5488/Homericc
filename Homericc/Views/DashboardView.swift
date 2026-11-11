import SwiftUI

struct DashboardView: View {
    @Environment(ServiceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    @Environment(Monitor.self) private var monitor

    private var statuses: [ServiceKind: Result<ServiceStatus, Error>] { monitor.statuses }
    private var sessions: [PlexItem] { monitor.sessions }
    private var recent: [PlexItem] { monitor.recentlyAdded }
    private var torrents: [Torrent] { monitor.torrents }
    private var transfer: TransferInfo? { monitor.transfer }
    private var pendingRequests: Int { monitor.pendingRequests.count }
    private var warnings: [(ServiceKind, ArrHealth)] { monitor.warnings }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tiles

                if !sessions.isEmpty {
                    DashboardSection("En lecture sur Plex") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                            ForEach(sessions) { item in
                                NowPlayingCard(item: item, imageURL: plex?.imageURL(item.artwork))
                            }
                        }
                    }
                }

                if !recent.isEmpty {
                    DashboardSection("Ajouts récents") {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(recent) { item in
                                    VStack(alignment: .leading, spacing: 6) {
                                        PosterImage(url: plex?.imageURL(item.artwork), symbol: "play.rectangle")
                                        Text(item.headline).font(.callout).lineLimit(1)
                                        if let subtitle = item.subtitle {
                                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .frame(width: 130)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }

                if !warnings.isEmpty {
                    DashboardSection("Alertes") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(warnings, id: \.1.id) { kind, health in
                                Label {
                                    Text("**\(kind.name)** · \(health.message)")
                                } icon: {
                                    Image(systemName: health.type == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(health.type == "error" ? .red : .orange)
                                }
                                .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
                    }
                }

                DashboardSection("Services") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(configured) { kind in
                            StatusRow(kind: kind, status: statuses[kind])
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.fill.quaternary, in: .rect(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(28)
        }
        .toolbar {
            ToolbarItem {
                Button { monitor.refreshNow() } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
        }
        // Live figures while on screen: the shared monitor speeds up instead of a second poller.
        .onAppear { monitor.setFastRefresh(true) }
        .onDisappear { monitor.setFastRefresh(false) }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
            if store.isConfigured(.qbittorrent) {
                let active = torrents.filter { !$0.isComplete }.count
                Tile(title: "Téléchargements", symbol: "arrow.down.circle.fill", tint: .blue,
                     value: transfer.map { $0.dl_info_speed.speed } ?? "–",
                     caption: active == 0 ? "Rien en cours" : "\(active) en cours") {
                    navigation.selection = .downloads
                }
            }
            if store.isConfigured(.seerr) {
                Tile(title: "Demandes", symbol: "hand.raised.fill", tint: .purple,
                     value: "\(pendingRequests)",
                     caption: pendingRequests == 0 ? "Aucune en attente" : "En attente d'approbation") {
                    navigation.selection = .requests
                }
            }
            if !sessions.isEmpty || store.isConfigured(.plex) {
                Tile(title: "Plex", symbol: "play.rectangle.fill", tint: .orange,
                     value: "\(sessions.count)",
                     caption: sessions.count == 1 ? "Lecture en cours" : "Lectures en cours") {
                    navigation.selection = .plex
                }
            }
            let online = statuses.values.filter { if case .success = $0 { true } else { false } }.count
            Tile(title: "Services", symbol: "server.rack", tint: online == configured.count ? .green : .red,
                 value: "\(online)/\(configured.count)",
                 caption: online == configured.count ? "Tous en ligne" : "Certains ne répondent pas") {}
        }
    }
}

private struct DashboardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            content
        }
    }
}

/// A key figure on the dashboard. Content layer: a system fill, not glass.
private struct Tile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.fill.quaternary, in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
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

private struct NowPlayingCard: View {
    let item: PlexItem
    let imageURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            PosterImage(url: imageURL, symbol: "play.rectangle")
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.headline).font(.headline).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Label([item.user?.title, item.player?.title ?? item.player?.product].compactMap(\.self).joined(separator: " · "),
                      systemImage: item.isPaused ? "pause.fill" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = item.progress {
                    ProgressView(value: progress)
                        .tint(item.isPaused ? .secondary : .orange)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }
}
