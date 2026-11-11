import Network
import SwiftUI

@main
struct HomericcApp: App {
    @State private var store = ServiceStore()
    @State private var navigation = AppNavigation()
    @State private var pathMonitor = NetworkWatcher()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(navigation)
                .onAppear { pathMonitor.start() }
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
                .environment(store)
                .environment(navigation)
        }
    }
}

@Observable
final class AppNavigation {
    var selection: SidebarItem? = .home
    /// The service shown when the Settings window opens.
    var settingsSelection: ServiceKind? = .radarr
}

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, movies, series, music, requests, downloads, indexers

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Accueil"
        case .movies: "Films"
        case .series: "Séries"
        case .music: "Musique"
        case .requests: "Demandes"
        case .downloads: "Téléchargements"
        case .indexers: "Indexeurs"
        }
    }

    /// The service behind the screen; the dashboard aggregates all of them.
    var service: ServiceKind? {
        switch self {
        case .home: nil
        case .movies: .radarr
        case .series: .sonarr
        case .music: .lidarr
        case .requests: .seerr
        case .downloads: .qbittorrent
        case .indexers: .prowlarr
        }
    }

    var symbol: String { service?.symbol ?? "house" }

    static let sections: [(String?, [SidebarItem])] = [
        (nil, [.home]),
        ("Bibliothèque", [.movies, .series, .music]),
        ("Serveur", [.requests, .downloads, .indexers]),
    ]
}

/// Leaving or joining the home network changes which address works: forget the cached choice.
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var lastStatus: String?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status = "\(path.status)-\(path.availableInterfaces.map(\.name))"
            Task { @MainActor in
                guard let self, self.lastStatus != status else { return }
                self.lastStatus = status
                ServiceConnection.invalidate()
            }
        }
        monitor.start(queue: DispatchQueue(label: "Homericc.network"))
    }
}

struct RootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServiceStore.self) private var store

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(SidebarItem.sections, id: \.1) { title, items in
                    Section {
                        ForEach(items) { item in
                            Label(item.title, systemImage: item.symbol)
                                .foregroundStyle(item.service.map(store.isConfigured) ?? true ? .primary : .secondary)
                        }
                    } header: {
                        if let title { Text(title) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            NavigationStack {
                detail(for: navigation.selection ?? .home)
            }
            .id(navigation.selection)
        }
    }

    @ViewBuilder private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .home: DashboardView()
        case .movies: LibraryView(kind: .radarr)
        case .series: LibraryView(kind: .sonarr)
        case .music: LibraryView(kind: .lidarr)
        case .requests: RequestsView()
        case .downloads: DownloadsView()
        case .indexers: ProwlarrView()
        }
    }
}
