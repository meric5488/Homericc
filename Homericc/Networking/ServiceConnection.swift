import Foundation

nonisolated enum ServiceError: LocalizedError {
    case notConfigured(ServiceKind)
    case unreachable(ServiceKind)
    case unauthorized(ServiceKind)
    case http(ServiceKind, Int)
    case invalidResponse(ServiceKind)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let kind): "\(kind.name) n'est pas configuré."
        case .unreachable(let kind): "\(kind.name) ne répond ni en local ni à distance."
        case .unauthorized(let kind): "\(kind.name) refuse l'accès : vérifie la clé ou les identifiants."
        case .http(let kind, let code): "\(kind.name) a répondu avec l'erreur \(code)."
        case .invalidResponse(let kind): "Réponse inattendue de \(kind.name)."
        }
    }
}

/// Talks to one service: picks the local address when it answers, falls back to the remote one,
/// and adds the right authentication to every request.
final class ServiceConnection {
    private static var cache: [ServiceKind: ServiceConnection] = [:]

    static func shared(for config: ServiceConfig, secret: String) -> ServiceConnection {
        if let existing = cache[config.kind], existing.config == config, existing.secret == secret {
            return existing
        }
        let connection = ServiceConnection(config: config, secret: secret)
        cache[config.kind] = connection
        return connection
    }

    /// Forgets the chosen addresses, e.g. after a settings change or when the network changes.
    static func invalidate() {
        cache.removeAll()
    }

    let config: ServiceConfig
    let secret: String
    var kind: ServiceKind { config.kind }

    /// The address that answered last time.
    private(set) var activeBase: URL?
    var isUsingRemote: Bool {
        guard let activeBase, config.candidateURLs.count > 1 else { return false }
        return activeBase == config.candidateURLs.last
    }

    private let session: URLSession
    private var didLogin = false

    private init(config: ServiceConfig, secret: String) {
        self.config = config
        self.secret = secret
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: configuration)
    }

    // MARK: Requests

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        try decode(await data(path, query: query))
    }

    func send<T: Decodable>(_ method: String, _ path: String, json: Any, as type: T.Type = T.self) async throws -> T {
        try decode(await data(path, method: method, body: JSONSerialization.data(withJSONObject: json)))
    }

    /// For calls whose answer we don't need.
    func perform(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil, form: [String: String]? = nil) async throws {
        var body: Data?
        var contentType: String?
        if let json {
            body = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            body = Self.formEncoded(form)
            contentType = "application/x-www-form-urlencoded"
        }
        _ = try await data(path, method: method, query: query, body: body, contentType: contentType)
    }

    func data(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
              contentType: String? = nil) async throws -> Data {
        if kind == .qbittorrent, !didLogin {
            try await loginToQBittorrent()
        }
        do {
            return try await rawData(path, method: method, query: query, body: body, contentType: contentType)
        } catch ServiceError.unauthorized(let kind) where kind == .qbittorrent && didLogin {
            // The qBittorrent session expired: log in again once.
            try await loginToQBittorrent()
            return try await rawData(path, method: method, query: query, body: body, contentType: contentType)
        }
    }

    /// Builds an absolute URL on the active address (for images), without network access.
    func url(_ path: String, query: [URLQueryItem] = []) -> URL? {
        guard let base = activeBase ?? config.candidateURLs.first else { return nil }
        return Self.makeURL(base: base, path: path, query: query)
    }

    // MARK: Internals

    private func rawData(_ path: String, method: String, query: [URLQueryItem], body: Data?,
                         contentType: String?) async throws -> Data {
        var bases = config.candidateURLs
        guard !bases.isEmpty else { throw ServiceError.notConfigured(kind) }
        if let activeBase, let index = bases.firstIndex(of: activeBase) {
            bases.swapAt(0, index)
        }

        for (position, base) in bases.enumerated() {
            guard let url = Self.makeURL(base: base, path: path, query: query) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            // Short timeout on the first try so an unreachable LAN address fails over quickly.
            request.timeoutInterval = position == 0 && bases.count > 1 ? 4 : 20
            if body != nil {
                request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
            }
            authorize(&request, base: base)

            let response: (Data, URLResponse)
            do {
                response = try await session.data(for: request)
            } catch let error as URLError where error.code != .cancelled {
                if activeBase == base { activeBase = nil }
                continue
            }
            activeBase = base

            guard let http = response.1 as? HTTPURLResponse else { throw ServiceError.invalidResponse(kind) }
            switch http.statusCode {
            case 200..<300: return response.0
            case 401, 403: throw ServiceError.unauthorized(kind)
            default: throw ServiceError.http(kind, http.statusCode)
            }
        }
        throw ServiceError.unreachable(kind)
    }

    private func authorize(_ request: inout URLRequest, base: URL) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch kind.credential {
        case .apiKey:
            request.setValue(secret, forHTTPHeaderField: "X-Api-Key")
        case .token:
            request.setValue(secret, forHTTPHeaderField: "X-Plex-Token")
            request.setValue("Homericc", forHTTPHeaderField: "X-Plex-Product")
            request.setValue("homericc-mac", forHTTPHeaderField: "X-Plex-Client-Identifier")
        case .login:
            // qBittorrent rejects requests whose Referer doesn't match its host (CSRF protection).
            request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
            // Seedboxes (Swizzin…) put qBittorrent behind nginx HTTP Basic auth with the same credentials.
            let basic = Data("\(config.username):\(secret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
    }

    private func loginToQBittorrent() async throws {
        let body = Self.formEncoded(["username": config.username, "password": secret])
        let data = try await rawData("/api/v2/auth/login", method: "POST", query: [], body: body,
                                     contentType: "application/x-www-form-urlencoded")
        if !String(decoding: data, as: UTF8.self).hasPrefix("Ok") {
            // Behind a proxy, qBittorrent often skips its own login (trusted local clients): check the API answers.
            _ = try await rawData("/api/v2/app/version", method: "GET", query: [], body: nil, contentType: nil)
        }
        didLogin = true
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceError.invalidResponse(kind)
        }
    }

    private static func makeURL(base: URL, path: String, query: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        return components?.url
    }

    private static func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
