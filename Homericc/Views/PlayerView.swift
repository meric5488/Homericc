import AVKit
import SwiftUI

/// The playback window: AppKit's player view brings the native controls, full screen and Picture in Picture.
struct PlayerView: View {
    let playback: PlexPlayback
    @Environment(ServiceStore.self) private var store
    @State private var model: PlayerModel?
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black
            if let model {
                AVPlayerViewBridge(player: model.player)
            } else if let error {
                ContentUnavailableView("Lecture impossible", systemImage: "exclamationmark.triangle", description: Text(error))
                    .foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .ignoresSafeArea()
        .navigationTitle(playback.title)
        .task { await start() }
        .onDisappear { model?.stop() }
    }

    private func start() async {
        guard model == nil, let connection = store.connection(for: .plex) else {
            if store.connection(for: .plex) == nil { error = "Plex n'est pas configuré." }
            return
        }
        let api = PlexAPI(connection: connection)
        do {
            guard let item = try await api.item(playback.ratingKey) else {
                error = "Ce média n'existe plus sur Plex."
                return
            }
            model = try PlayerModel(api: api, item: item, startOffset: playback.startOffset)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@Observable
final class PlayerModel {
    let player: AVPlayer
    private let api: PlexAPI
    private let item: PlexItem
    private let session = UUID().uuidString
    private var timeObserver: Any?
    private var stopped = false

    init(api: PlexAPI, item: PlexItem, startOffset: Int) throws {
        guard let url = api.streamURL(for: item, session: session) else {
            throw ServiceError.invalidResponse(.plex)
        }
        self.api = api
        self.item = item
        // HLS segment requests carry no token in their URLs: send it as a header on every request.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["X-Plex-Token": api.connection.secret]])
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        if startOffset > 0 {
            player.seek(to: CMTime(value: CMTimeValue(startOffset), timescale: 1000))
        }
        player.play()

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(state: self?.player.rate == 0 ? "paused" : "playing") }
        }
    }

    private var currentMilliseconds: Int {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? Int(seconds * 1000) : 0
    }

    private func report(state: String) {
        let api = api, item = item, time = currentMilliseconds
        Task { await api.reportTimeline(item, state: state, time: time) }
    }

    /// Saves the position in Plex, marks the item watched near the end, and ends the transcode session.
    func stop() {
        guard !stopped else { return }
        stopped = true
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        let api = api, item = item, session = session, time = currentMilliseconds
        let finished = (item.duration ?? 0) > 0 && Double(time) / Double(item.duration ?? 1) > 0.9
        Task {
            await api.reportTimeline(item, state: "stopped", time: time)
            if finished { await api.markWatched(item) }
            await api.stopTranscode(session: session)
        }
    }
}

private struct AVPlayerViewBridge: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.showsSharingServiceButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
