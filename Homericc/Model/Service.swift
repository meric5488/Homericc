import Foundation
import Observation

/// The self-hosted services Homericc talks to.
nonisolated enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case radarr, sonarr, lidarr, prowlarr, seerr, plex, qbittorrent

    var id: String { rawValue }

    var name: String {
        switch self {
        case .radarr: "Radarr"
        case .sonarr: "Sonarr"
        case .lidarr: "Lidarr"
        case .prowlarr: "Prowlarr"
        case .seerr: "Seerr"
        case .plex: "Plex"
        case .qbittorrent: "qBittorrent"
        }
    }

    var role: String {
        switch self {
        case .radarr: "Films"
        case .sonarr: "Séries"
        case .lidarr: "Musique"
        case .prowlarr: "Indexeurs"
        case .seerr: "Demandes"
        case .plex: "Serveur multimédia"
        case .qbittorrent: "Téléchargements"
        }
    }

    var symbol: String {
        switch self {
        case .radarr: "film"
        case .sonarr: "tv"
        case .lidarr: "music.note"
        case .prowlarr: "magnifyingglass"
        case .seerr: "hand.raised"
        case .plex: "play.rectangle"
        case .qbittorrent: "arrow.down.circle"
        }
    }

    var defaultPort: Int {
        switch self {
        case .radarr: 7878
        case .sonarr: 8989
        case .lidarr: 8686
        case .prowlarr: 9696
        case .seerr: 5055
        case .plex: 32400
        case .qbittorrent: 8080
        }
    }

    /// What the secret field holds for this service.
    var credential: Credential {
        switch self {
        case .plex: .token
        case .qbittorrent: .login
        default: .apiKey
        }
    }

    enum Credential { case apiKey, token, login }
}

/// One configured server. Secrets live in the keychain, not here.
struct ServiceConfig: Codable, Identifiable, Hashable {
    var kind: ServiceKind
    /// Address on the home network, tried first.
    var localURL: String = ""
    /// Address from outside (domain, reverse proxy, Tailscale…), used when the local one doesn't answer.
    var remoteURL: String = ""
    var username: String = ""
    var isEnabled: Bool = true

    var id: ServiceKind { kind }

    var candidateURLs: [URL] {
        [localURL, remoteURL]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { raw in
                let withScheme = raw.contains("://") ? raw : "http://\(raw)"
                return URL(string: withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme)
            }
    }

    var isConfigured: Bool { isEnabled && !candidateURLs.isEmpty }
}

/// Holds the server list and persists it.
@Observable
final class ServiceStore {
    private(set) var configs: [ServiceKind: ServiceConfig] = [:]
    /// Bumped whenever a config or secret changes, so screens reload.
    private(set) var revision = 0

    private let defaultsKey = "services.v1"
    /// All secrets live in one keychain item, so macOS asks for access once rather than once per service.
    private let secretsAccount = "secrets.v1"
    private var secrets: [String: String] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([ServiceConfig].self, from: data) {
            configs = Dictionary(uniqueKeysWithValues: list.map { ($0.kind, $0) })
        }
        loadSecrets()
    }

    private func loadSecrets() {
        if let json = Keychain.read(account: secretsAccount),
           let stored = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
            secrets = stored
            return
        }
        // First launch after the change: move the old one-item-per-service secrets into the shared item.
        for kind in ServiceKind.allCases {
            if let old = Keychain.read(account: kind.rawValue) {
                secrets[kind.rawValue] = old
            }
        }
        if !secrets.isEmpty {
            persistSecrets()
            ServiceKind.allCases.forEach { Keychain.delete(account: $0.rawValue) }
        }
    }

    private func persistSecrets() {
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        Keychain.write(String(decoding: data, as: UTF8.self), account: secretsAccount)
    }

    func config(for kind: ServiceKind) -> ServiceConfig {
        configs[kind] ?? ServiceConfig(kind: kind)
    }

    func isConfigured(_ kind: ServiceKind) -> Bool {
        configs[kind]?.isConfigured ?? false
    }

    func secret(for kind: ServiceKind) -> String {
        secrets[kind.rawValue] ?? ""
    }

    func save(_ config: ServiceConfig, secret: String) {
        configs[config.kind] = config
        secrets[config.kind.rawValue] = secret.isEmpty ? nil : secret
        persistSecrets()
        persist()
    }

    func remove(_ kind: ServiceKind) {
        configs[kind] = nil
        secrets[kind.rawValue] = nil
        persistSecrets()
        persist()
    }

    func connection(for kind: ServiceKind) -> ServiceConnection? {
        let config = config(for: kind)
        guard config.isConfigured else { return nil }
        return ServiceConnection.shared(for: config, secret: secret(for: kind))
    }

    private func persist() {
        let list = configs.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: defaultsKey)
        ServiceConnection.invalidate()
        revision += 1
    }
}
