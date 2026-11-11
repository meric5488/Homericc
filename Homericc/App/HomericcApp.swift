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
    }
}

@Observable
final class AppNavigation {
    var tab: AppTab = .home
}

enum AppTab: Hashable {
    case home, library, requests, downloads, settings
}

/// Leaving or joining the home Wi-Fi changes which address works: forget the cached choice.
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

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab("Accueil", systemImage: "house", value: AppTab.home) {
                DashboardView()
            }
            Tab("Bibliothèque", systemImage: "film.stack", value: AppTab.library) {
                LibraryView()
            }
            Tab("Demandes", systemImage: "hand.raised", value: AppTab.requests) {
                RequestsView()
            }
            Tab("Téléchargements", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                DownloadsView()
            }
            Tab("Réglages", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
