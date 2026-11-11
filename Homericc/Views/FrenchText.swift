import NaturalLanguage
import SwiftUI
import Translation

/// French summaries: TMDB's French text through Seerr for movies and series,
/// on-device translation for the rest (music metadata only exists in English).
@Observable
final class FrenchOverviews {
    static let shared = FrenchOverviews()
    private var cache: [String: String] = [:]

    func cached(_ key: String) -> String? { cache[key] }

    func store(_ text: String, for key: String) { cache[key] = text }

    /// The TMDB French overview, nil when Seerr isn't set up or has none.
    func fromTMDB(_ item: ArrItem, store services: ServiceStore) async -> String? {
        guard item.kind != .lidarr, let tmdbID = item.tmdbID,
              let connection = services.connection(for: .seerr) else { return nil }
        let details = try? await SeerrAPI(connection: connection)
            .details(mediaType: item.kind == .radarr ? "movie" : "tv", tmdbID: tmdbID, language: "fr")
        return details?.overview.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func isFrench(_ text: String) -> Bool {
        NLLanguageRecognizer.dominantLanguage(for: text) == .french
    }
}

/// Shows an item's overview in French, falling back to the original while it's being fetched.
struct FrenchOverview: View {
    let item: ArrItem
    let original: String
    var lineLimit: Int?

    @Environment(ServiceStore.self) private var store
    @State private var text: String?
    @State private var translation: TranslationSession.Configuration?

    private var key: String { "\(item.kind.rawValue)-\(item.id)" }

    var body: some View {
        Text(text ?? original)
            .lineLimit(lineLimit)
            .animation(.easeOut(duration: 0.2), value: text)
            .task(id: key) { await resolve() }
            .translationTask(translation) { session in
                // The session is only used inside this closure, as the Translation API intends.
                nonisolated(unsafe) let session = session
                guard let response = try? await session.translate(original) else { return }
                FrenchOverviews.shared.store(response.targetText, for: key)
                text = response.targetText
            }
    }

    private func resolve() async {
        let overviews = FrenchOverviews.shared
        if let cached = overviews.cached(key) { text = cached; return }
        if FrenchOverviews.isFrench(original) { return }
        if let french = await overviews.fromTMDB(item, store: store) {
            overviews.store(french, for: key)
            text = french
            return
        }
        // No French source: translate on the Mac (macOS may offer to download the language once).
        translation = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: "fr"))
    }
}
