import Foundation

struct Torrent: Identifiable, Decodable {
    let hash: String
    let name: String
    let progress: Double
    let dlspeed: Int64
    let upspeed: Int64
    let size: Int64
    let eta: Int
    let state: String
    let category: String?

    var id: String { hash }

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

    func pause(_ torrent: Torrent) async throws {
        try await command(v5: "stop", v4: "pause", hash: torrent.hash)
    }

    func resume(_ torrent: Torrent) async throws {
        try await command(v5: "start", v4: "resume", hash: torrent.hash)
    }

    func delete(_ torrent: Torrent, deleteFiles: Bool) async throws {
        try await connection.perform("POST", "/api/v2/torrents/delete",
                                     form: ["hashes": torrent.hash, "deleteFiles": deleteFiles ? "true" : "false"])
    }

    /// qBittorrent 5 renamed pause/resume to stop/start.
    private func command(v5: String, v4: String, hash: String) async throws {
        do {
            try await connection.perform("POST", "/api/v2/torrents/\(v5)", form: ["hashes": hash])
        } catch ServiceError.http(_, 404) {
            try await connection.perform("POST", "/api/v2/torrents/\(v4)", form: ["hashes": hash])
        }
    }
}
