import Foundation

nonisolated struct Torrent: Identifiable, Decodable, Sendable {
    let hash: String
    let name: String
    let progress: Double
    let dlspeed: Int64
    let upspeed: Int64
    let size: Int64
    let eta: Int
    let state: String
    let category: String?
    let ratio: Double
    let added_on: Int?

    var id: String { hash }
    var addedOn: Int { added_on ?? 0 }
    var addedDate: Date? { added_on.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    var isPaused: Bool { state.hasPrefix("paused") || state.hasPrefix("stopped") }
    var isComplete: Bool { progress >= 1 }
    var hasError: Bool { state == "error" || state == "missingFiles" }

    var stateLabel: String {
        switch state {
        case "downloading", "forcedDL": "Téléchargement"
        case "metaDL", "forcedMetaDL": "Métadonnées"
        case "stalledDL": "Bloqué"
        case "uploading", "forcedUP", "stalledUP": "Partage"
        case "queuedDL", "queuedUP": "En file"
        case "checkingDL", "checkingUP", "checkingResumeData": "Vérification"
        case "moving": "Déplacement"
        case "error", "missingFiles": "Erreur"
        default: isPaused ? (isComplete ? "Terminé" : "En pause") : state
        }
    }

    /// qBittorrent uses 8640000 for "infinity".
    var remaining: Duration? {
        guard !isComplete, !isPaused, eta > 0, eta < 8_640_000 else { return nil }
        return .seconds(eta)
    }
}

struct TransferInfo: Decodable {
    let dl_info_speed: Int64
    let up_info_speed: Int64
}

struct QBittorrentAPI {
    let connection: ServiceConnection

    func torrents() async throws -> [Torrent] {
        try await connection.get("/api/v2/torrents/info", query: [URLQueryItem(name: "sort", value: "added_on"),
                                                                   URLQueryItem(name: "reverse", value: "true")])
    }

    func transfer() async throws -> TransferInfo {
        try await connection.get("/api/v2/transfer/info")
    }

    func pause(_ torrents: [Torrent]) async throws {
        try await command(v5: "stop", v4: "pause", hashes: torrents)
    }

    func resume(_ torrents: [Torrent]) async throws {
        try await command(v5: "start", v4: "resume", hashes: torrents)
    }

    func delete(_ torrents: [Torrent], deleteFiles: Bool) async throws {
        try await connection.perform("POST", "/api/v2/torrents/delete",
                                     form: ["hashes": Self.join(torrents), "deleteFiles": deleteFiles ? "true" : "false"])
    }

    private static func join(_ torrents: [Torrent]) -> String {
        torrents.map(\.hash).joined(separator: "|")
    }

    /// qBittorrent 5 renamed pause/resume to stop/start.
    private func command(v5: String, v4: String, hashes torrents: [Torrent]) async throws {
        let hashes = Self.join(torrents)
        do {
            try await connection.perform("POST", "/api/v2/torrents/\(v5)", form: ["hashes": hashes])
        } catch ServiceError.http(_, 404) {
            try await connection.perform("POST", "/api/v2/torrents/\(v4)", form: ["hashes": hashes])
        }
    }
}

/// Keeps a torrent list current with qBittorrent's incremental sync: after the first call,
/// each refresh only carries the torrents and fields that changed.
final class TorrentSync {
    private let api: QBittorrentAPI
    private var rid = 0
    private var raw: [String: [String: Any]] = [:]
    private var decoded: [String: Torrent] = [:]
    private var serverState: [String: Any] = [:]

    init(api: QBittorrentAPI) {
        self.api = api
    }

    func update() async throws -> (torrents: [Torrent], transfer: TransferInfo) {
        let data: [String: Any]
        do {
            data = try await api.mainData(rid: rid)
        } catch {
            rid = 0 // Start over with a full update next time.
            throw error
        }
        if data["full_update"] as? Bool == true {
            raw = [:]
            decoded = [:]
        }
        rid = data["rid"] as? Int ?? 0

        for hash in data["torrents_removed"] as? [String] ?? [] {
            raw[hash] = nil
            decoded[hash] = nil
        }
        for (hash, changes) in data["torrents"] as? [String: [String: Any]] ?? [:] {
            var merged = raw[hash] ?? ["hash": hash]
            merged.merge(changes) { _, new in new }
            raw[hash] = merged
            // Only re-decode torrents that changed.
            if let json = try? JSONSerialization.data(withJSONObject: merged),
               let torrent = try? JSONDecoder().decode(Torrent.self, from: json) {
                decoded[hash] = torrent
            }
        }
        if let state = data["server_state"] as? [String: Any] {
            serverState.merge(state) { _, new in new }
        }
        let transfer = TransferInfo(dl_info_speed: (serverState["dl_info_speed"] as? NSNumber)?.int64Value ?? 0,
                                    up_info_speed: (serverState["up_info_speed"] as? NSNumber)?.int64Value ?? 0)
        return (Array(decoded.values), transfer)
    }
}

extension QBittorrentAPI {
    func mainData(rid: Int) async throws -> [String: Any] {
        let data = try await connection.data("/api/v2/sync/maindata", query: [URLQueryItem(name: "rid", value: String(rid))])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.invalidResponse(.qbittorrent)
        }
        return object
    }
}
