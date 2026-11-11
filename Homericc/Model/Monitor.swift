import Foundation
import Observation
import UserNotifications

/// App-wide preferences that aren't about one service.
@Observable
final class AppSettings {
    var showInDock: Bool { didSet { save() } }
    var showInMenuBar: Bool { didSet { save() } }
    var notifyDownloads: Bool { didSet { save() } }
    var notifyRequests: Bool { didSet { save() } }
    var notifyOffline: Bool { didSet { save() } }

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: ["showInDock": false, "showInMenuBar": true, "notifyDownloads": true,
                                     "notifyRequests": true, "notifyOffline": true])
        showInDock = defaults.bool(forKey: "showInDock")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        notifyDownloads = defaults.bool(forKey: "notifyDownloads")
        notifyRequests = defaults.bool(forKey: "notifyRequests")
        notifyOffline = defaults.bool(forKey: "notifyOffline")
    }

    private func save() {
        defaults.set(showInDock, forKey: "showInDock")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        defaults.set(notifyDownloads, forKey: "notifyDownloads")
        defaults.set(notifyRequests, forKey: "notifyRequests")
        defaults.set(notifyOffline, forKey: "notifyOffline")
    }
}

/// Polls the servers in the background, keeps a summary for the menu bar, and posts notifications
/// when a download finishes, a request arrives or a service stops answering.
@Observable
final class Monitor {
    private(set) var torrents: [Torrent] = []
    private(set) var transfer: TransferInfo?
    private(set) var pendingRequests: [SeerrRequest] = []
    private(set) var sessions: [PlexItem] = []
    private(set) var offline: Set<ServiceKind> = []
    private(set) var lastUpdate: Date?

    private let store: ServiceStore
    private let settings: AppSettings
    private var task: Task<Void, Never>?
    private var seeded = false
    private var incompleteHashes: Set<String> = []
    private var knownRequests: Set<Int> = []

    init(store: ServiceStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard task == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        task = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refreshNow() {
        Task { await poll() }
    }

    private func poll() async {
        if let connection = store.connection(for: .qbittorrent) {
            let api = QBittorrentAPI(connection: connection)
            if let list = try? await api.torrents() {
                torrents = list
                transfer = try? await api.transfer()
                checkFinishedDownloads(list)
                offline.remove(.qbittorrent)
            } else {
                markOffline(.qbittorrent)
            }
        }

        if let connection = store.connection(for: .seerr) {
            let api = SeerrAPI(connection: connection)
            if let requests = try? await api.requests() {
                pendingRequests = requests.filter(\.isPending)
                await checkNewRequests(pendingRequests, api: api)
                offline.remove(.seerr)
            } else {
                markOffline(.seerr)
            }
        }

        if let connection = store.connection(for: .plex) {
            sessions = (try? await PlexAPI(connection: connection).sessions()) ?? []
        }

        // The *arrs only need a reachability check.
        for kind in [ServiceKind.radarr, .sonarr, .lidarr, .prowlarr, .plex] {
            guard let connection = store.connection(for: kind) else { continue }
            if (try? await ServiceStatus.check(connection)) != nil {
                offline.remove(kind)
            } else {
                markOffline(kind)
            }
        }

        seeded = true
        lastUpdate = .now
    }

    private func checkFinishedDownloads(_ list: [Torrent]) {
        let finished = list.filter { $0.isComplete && incompleteHashes.contains($0.hash) }
        incompleteHashes = Set(list.filter { !$0.isComplete }.map(\.hash))
        guard seeded, settings.notifyDownloads else { return }
        for torrent in finished {
            notify(id: "download-\(torrent.hash)", title: "Téléchargement terminé", body: torrent.name)
        }
        if !finished.isEmpty { PlexIndex.shared.invalidate() }
    }

    private func checkNewRequests(_ requests: [SeerrRequest], api: SeerrAPI) async {
        let new = requests.filter { !knownRequests.contains($0.id) }
        knownRequests.formUnion(requests.map(\.id))
        guard seeded, settings.notifyRequests else { return }
        for request in new {
            let title = (try? await api.details(for: request))?.displayTitle ?? (request.isMovie ? "Un film" : "Une série")
            notify(id: "request-\(request.id)", title: "Nouvelle demande",
                   body: "\(title) · demandé par \(request.requestedBy?.displayName ?? "quelqu'un")")
        }
    }

    private func markOffline(_ kind: ServiceKind) {
        let wasOnline = !offline.contains(kind)
        offline.insert(kind)
        guard seeded, wasOnline, settings.notifyOffline else { return }
        notify(id: "offline-\(kind.rawValue)", title: "\(kind.name) ne répond plus",
               body: "Ni l'adresse locale ni l'adresse distante ne répondent.")
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
