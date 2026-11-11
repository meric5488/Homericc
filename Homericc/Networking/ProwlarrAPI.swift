import Foundation

struct ProwlarrIndexer: Identifiable, Decodable {
    let id: Int
    let name: String
    let enable: Bool
    let `protocol`: String?
}

struct ProwlarrIndexerStatus: Decodable {
    let indexerId: Int
    let disabledTill: String?
}

struct ProwlarrRelease: Identifiable, Decodable {
    let guid: String
    let title: String
    let indexer: String?
    let size: Int64?
    let seeders: Int?
    let age: Int?
    let indexerId: Int?
    let `protocol`: String?

    var id: String { guid }
}

struct ProwlarrAPI {
    let connection: ServiceConnection

    func indexers() async throws -> [ProwlarrIndexer] {
        try await connection.get("/api/v1/indexer")
    }

    /// Indexers Prowlarr has temporarily disabled after failures.
    func failingIndexerIDs() async throws -> Set<Int> {
        let statuses: [ProwlarrIndexerStatus] = try await connection.get("/api/v1/indexerstatus")
        return Set(statuses.map(\.indexerId))
    }

    func test(_ indexer: ProwlarrIndexer) async throws {
        let data = try await connection.data("/api/v1/indexer/\(indexer.id)")
        try await connection.perform("POST", "/api/v1/indexer/test",
                                     json: JSONSerialization.jsonObject(with: data))
    }

    func search(_ query: String) async throws -> [ProwlarrRelease] {
        try await connection.get("/api/v1/search", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "type", value: "search"),
        ])
    }

    /// Sends a release to the matching download client configured in Prowlarr.
    func grab(_ release: ProwlarrRelease) async throws {
        try await connection.perform("POST", "/api/v1/search",
                                     json: ["guid": release.guid, "indexerId": release.indexerId ?? 0])
    }
}

/// Lightweight reachability check used by the dashboard.
struct ServiceStatus {
    let version: String?
    let isRemote: Bool

    static func check(_ connection: ServiceConnection) async throws -> ServiceStatus {
        let version: String?
        switch connection.kind {
        case .radarr, .sonarr, .lidarr, .prowlarr:
            struct Status: Decodable { let version: String? }
            let api = connection.kind == .radarr || connection.kind == .sonarr ? "v3" : "v1"
            version = (try await connection.get("/api/\(api)/system/status", as: Status.self)).version
        case .seerr:
            struct Status: Decodable { let version: String? }
            version = (try await connection.get("/api/v1/status", as: Status.self)).version
            // /status is public: confirm the key with an authenticated call.
            _ = try await connection.data("/api/v1/settings/main")
        case .plex:
            struct Identity: Decodable {
                let MediaContainer: Container
                struct Container: Decodable { let version: String? }
            }
            version = (try await connection.get("/identity", as: Identity.self)).MediaContainer.version
            _ = try await connection.data("/library/sections")
        case .qbittorrent:
            version = String(decoding: try await connection.data("/api/v2/app/version"), as: UTF8.self)
        }
        return ServiceStatus(version: version, isRemote: connection.isUsingRemote)
    }
}
