import Network
import SwiftUI

@main
struct HomericcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: ServiceStore
    @State private var settings: AppSettings
    @State private var monitor: Monitor
    @State private var navigation = AppNavigation()
    @State private var pathMonitor = NetworkWatcher()

    init() {
        let store = ServiceStore()
        let settings = AppSettings()
        _store = State(initialValue: store)
        _settings = State(initialValue: settings)
        _monitor = State(initialValue: Monitor(store: store, settings: settings))
        AppDelegate.settings = settings
    }

    var body: some Scene {
        Window("Homericc", id: "main") {
            RootView()
                .environment(store)
                .environment(navigation)
                .environment(monitor)
                .onAppear {
                    pathMonitor.start()
                    monitor.start()
                }
        }
        .defaultSize(width: 1100, height: 720)

        WindowGroup("Lecture", id: "player", for: PlexPlayback.self) { $playback in
            if let playback {
                PlayerView(playback: playback)
                    .environment(store)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)

        MenuBarExtra(isInserted: $settings.showInMenuBar) {
            MenuBarView()
                .environment(store)
                .environment(navigation)
                .environment(monitor)
                .onAppear { monitor.start() }
        } label: {
            Label("Homericc", systemImage: monitor.offline.isEmpty ? "play.house.fill" : "exclamationmark.triangle.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(navigation)
                .environment(settings)
        }
    }
}

/// Dock icon on or off, and staying alive in the menu bar when the window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var settings: AppSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyDockPolicy()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Self.settings?.showInMenuBar ?? false)
    }

    /// Clicking the Dock icon (or reopening from Finder) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    static func applyDockPolicy() {
        guard let settings else { return }
        // Without the menu bar item the Dock icon is the only way back to the app.
        let showDock = settings.showInDock || !settings.showInMenuBar
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }
}

@Observable
final class AppNavigation {
    var selection: SidebarItem? = .home
    /// The page shown when the Settings window opens.
    var settingsSelection: SettingsPage? = .general
    /// Counts shown next to sidebar items.
    var badges: [SidebarItem: Int] = [:]
}

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, search, calendar, plex, movies, series, music, requests, downloads, indexers

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Accueil"
        case .search: "Rechercher"
        case .calendar: "Calendrier"
        case .plex: "Plex"
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
        case .home, .search, .calendar: nil
        case .plex: .plex
        case .movies: .radarr
        case .series: .sonarr
        case .music: .lidarr
        case .requests: .seerr
        case .downloads: .qbittorrent
        case .indexers: .prowlarr
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .calendar: "calendar"
        default: service?.symbol ?? "circle"
        }
    }

    static let sections: [(String?, [SidebarItem])] = [
        (nil, [.home, .search, .calendar]),
        ("Regarder", [.plex]),
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
                                .badge(navigation.badges[item] ?? 0)
                        }
                    } header: {
                        if let title { Text(title) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .task(id: store.revision) {
                while !Task.isCancelled {
                    await refreshBadges()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        } detail: {
            NavigationStack {
                detail(for: navigation.selection ?? .home)
            }
            .id(navigation.selection)
        }
    }

    private func refreshBadges() async {
        if let connection = store.connection(for: .seerr) {
            let requests = (try? await SeerrAPI(connection: connection).requests()) ?? []
            navigation.badges[.requests] = requests.filter { $0.isPending }.count
        } else {
            navigation.badges[.requests] = nil
        }
        if let connection = store.connection(for: .qbittorrent) {
            let torrents = (try? await QBittorrentAPI(connection: connection).torrents()) ?? []
            navigation.badges[.downloads] = torrents.filter { !$0.isComplete && !$0.isPaused }.count
        } else {
            navigation.badges[.downloads] = nil
        }
    }

    @ViewBuilder private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .home: DashboardView()
        case .search: SearchView()
        case .calendar: CalendarView()
        case .plex: PlexHomeView()
        case .movies: LibraryView(kind: .radarr)
        case .series: LibraryView(kind: .sonarr)
        case .music: LibraryView(kind: .lidarr)
        case .requests: RequestsView()
        case .downloads: DownloadsView()
        case .indexers: ProwlarrView()
        }
    }
}
