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

/// The one place that polls the servers. The dashboard, the menu bar, the sidebar badges and
/// notifications all read from it, so each server gets one set of requests per refresh.
@Observable
final class Monitor {
    private(set) var torrents: [Torrent] = []
    private(set) var transfer: TransferInfo?
    private(set) var pendingRequests: [SeerrRequest] = []
    private(set) var sessions: [PlexItem] = []
    private(set) var recentlyAdded: [PlexItem] = []
    private(set) var warnings: [(ServiceKind, ArrHealth)] = []
    private(set) var statuses: [ServiceKind: Result<ServiceStatus, Error>] = [:]
    private(set) var lastUpdate: Date?

    var offline: Set<ServiceKind> {
        Set(statuses.compactMap { kind, result in if case .failure = result { kind } else { nil } })
    }

    private let store: ServiceStore
    private let settings: AppSettings
    private var task: Task<Void, Never>?
    private var seeded = false
    private var incompleteHashes: Set<String> = []
    private var knownRequests: Set<Int> = []
    private var torrentSync: (ServiceConnection, TorrentSync)?
    /// Versions only change on upgrades: fetched now and then, not on every poll.
    private var versions: [ServiceKind: String] = [:]
    private var versionsFetchedAt: Date?
    private var fastRefreshViewers = 0
    private var lastPoll: Date = .distantPast
    private var revision = -1

    init(store: ServiceStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    private var interval: TimeInterval { fastRefreshViewers > 0 ? 15 : 30 }

    func start() {
        guard task == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        task = Task {
            while !Task.isCancelled {
                if store.revision != revision {
                    // Settings changed: forget per-service state.
                    revision = store.revision
                    statuses = [:]
                    versionsFetchedAt = nil
                    torrentSync = nil
                    lastPoll = .distantPast
                }
                if Date.now.timeIntervalSince(lastPoll) >= interval {
                    lastPoll = .now
                    await poll()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refreshNow() {
        lastPoll = .distantPast
    }

    /// Screens that show live figures (the dashboard) ask for a faster pace while visible.
    func setFastRefresh(_ enabled: Bool) {
        fastRefreshViewers = max(0, fastRefreshViewers + (enabled ? 1 : -1))
        if enabled { refreshNow() }
    }

    private func poll() async {
        let refreshVersions = versionsFetchedAt.map { Date.now.timeIntervalSince($0) > 600 } ?? true
        if refreshVersions { versionsFetchedAt = .now }

        // Every service at once; each part updates its own state.
        var tasks: [Task<Void, Never>] = []
        if let connection = store.connection(for: .qbittorrent) {
            tasks.append(Task { await pollTorrents(connection, version: refreshVersions) })
        }
        if let connection = store.connection(for: .seerr) {
            tasks.append(Task { await pollRequests(connection, version: refreshVersions) })
        }
        if let connection = store.connection(for: .plex) {
            tasks.append(Task { await pollPlex(connection, version: refreshVersions) })
        }
        for kind in [ServiceKind.radarr, .sonarr, .lidarr, .prowlarr] {
            guard let connection = store.connection(for: kind) else { continue }
            tasks.append(Task { await pollArr(connection) })
        }
        for task in tasks { await task.value }

        let checked = Set(ServiceKind.allCases.filter(store.isConfigured))
        warnings = warnings.filter { checked.contains($0.0) }
        seeded = true
        lastUpdate = .now
    }

    private func pollTorrents(_ connection: ServiceConnection, version: Bool) async {
        if torrentSync?.0 !== connection {
            torrentSync = (connection, TorrentSync(api: QBittorrentAPI(connection: connection)))
        }
        do {
            let (list, info) = try await torrentSync!.1.update()
            torrents = list
            transfer = info
            checkFinishedDownloads(list)
            if version { versions[.qbittorrent] = try? await ServiceStatus.check(connection).version }
            setOnline(.qbittorrent, connection)
        } catch {
            setOffline(.qbittorrent, error)
        }
    }

    private func pollRequests(_ connection: ServiceConnection, version: Bool) async {
        let api = SeerrAPI(connection: connection)
        do {
            pendingRequests = try await api.requests().filter(\.isPending)
            await checkNewRequests(pendingRequests, api: api)
            if version { versions[.seerr] = try? await ServiceStatus.check(connection).version }
            setOnline(.seerr, connection)
        } catch {
            setOffline(.seerr, error)
        }
    }

    private func pollPlex(_ connection: ServiceConnection, version: Bool) async {
        let api = PlexAPI(connection: connection)
        do {
            sessions = try await api.sessions()
            if version {
                versions[.plex] = try? await ServiceStatus.check(connection).version
                // Recently added changes slowly: refresh it at the same pace as versions.
                recentlyAdded = (try? await api.recentlyAdded()) ?? recentlyAdded
            } else if recentlyAdded.isEmpty {
                recentlyAdded = (try? await api.recentlyAdded()) ?? []
            }
            setOnline(.plex, connection)
        } catch {
            setOffline(.plex, error)
        }
    }

    /// One status call per *arr gives reachability and version; health warnings come along for the three libraries.
    private func pollArr(_ connection: ServiceConnection) async {
        let kind = connection.kind
        do {
            let status = try await ServiceStatus.check(connection)
            versions[kind] = status.version
            setOnline(kind, connection)
            if kind != .prowlarr {
                let health = (try? await ArrAPI(connection: connection).health()) ?? []
                warnings = warnings.filter { $0.0 != kind } + health.filter { $0.type != "notice" }.map { (kind, $0) }
            }
        } catch {
            setOffline(kind, error)
        }
    }

    private func setOnline(_ kind: ServiceKind, _ connection: ServiceConnection) {
        statuses[kind] = .success(ServiceStatus(version: versions[kind], isRemote: connection.isUsingRemote))
    }

    private func setOffline(_ kind: ServiceKind, _ error: Error) {
        let wasOnline = !offline.contains(kind)
        statuses[kind] = .failure(error)
        guard seeded, wasOnline, settings.notifyOffline else { return }
        notify(id: "offline-\(kind.rawValue)", title: "\(kind.name) ne répond plus",
               body: "Ni l'adresse locale ni l'adresse distante ne répondent.")
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

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
