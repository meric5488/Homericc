import AVKit
import SwiftUI

/// The playback window: AppKit's player view brings the native controls, full screen and Picture in Picture;
/// audio and subtitle menus float above the video while the pointer moves.
struct PlayerView: View {
    let playback: PlexPlayback
    /// Set when the player is embedded in the main window.
    var onClose: (() -> Void)?
    var onDetach: ((PlexPlayback) -> Void)?
    @Environment(ServiceStore.self) private var store
    @State private var model: PlayerModel?
    @State private var error: String?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if let model {
                AVPlayerViewBridge(player: model.player)
                // Top trailing: the window's own buttons stay free on the leading side.
                HStack(spacing: 12) {
                    if model.hasTrackChoices { TrackMenus(model: model) }
                    if onClose != nil { windowControls(model) }
                }
                .padding(16)
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: controlsVisible)
                if model.isRestarting {
                    ProgressView().controlSize(.large).tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let error {
                ContentUnavailableView("Lecture impossible", systemImage: "exclamationmark.triangle", description: Text(error))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.large).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .navigationTitle(playback.title)
        .onExitCommand { onClose?() }
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .task { await start() }
        .onDisappear { model?.stop() }
    }

    private func windowControls(_ model: PlayerModel) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button { onClose?() } label: {
                    Label("Fermer", systemImage: "xmark")
                }
                .help("Fermer la lecture (Échap)")
                Button {
                    onDetach?(PlexPlayback(ratingKey: playback.ratingKey, title: playback.title,
                                           startOffset: model.currentMilliseconds))
                } label: {
                    Label("Détacher", systemImage: "macwindow.on.rectangle")
                }
                .help("Continuer dans une fenêtre séparée")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { controlsVisible = false }
        }
    }

    private func start() async {
        guard model == nil else { return }
        guard let connection = store.connection(for: .plex) else {
            error = "Plex n'est pas configuré."
            return
        }
        let api = PlexAPI(connection: connection)
        do {
            guard let item = try await api.item(playback.ratingKey) else {
                error = "Ce média n'existe plus sur Plex."
                return
            }
            model = try PlayerModel(api: api, item: item, startOffset: playback.startOffset)
            showControls()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Audio and subtitle pickers: the only custom controls over the video, so they get the glass.
private struct TrackMenus: View {
    let model: PlayerModel

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if model.audioTracks.count > 1 {
                    Menu {
                        Picker("Audio", selection: Binding(get: { model.selectedAudio }, set: { model.selectAudio($0) })) {
                            ForEach(model.audioTracks) { Text($0.label).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Audio", systemImage: "speaker.wave.2")
                    }
                    .help("Langue audio")
                }
                if !model.subtitleTracks.isEmpty {
                    Menu {
                        Picker("Sous-titres", selection: Binding(get: { model.selectedSubtitle ?? 0 },
                                                                 set: { model.selectSubtitle($0 == 0 ? nil : $0) })) {
                            Text("Désactivés").tag(0)
                            ForEach(model.subtitleTracks) { Text($0.label).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sous-titres", systemImage: "captions.bubble")
                    }
                    .help("Sous-titres")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(model.isRestarting)
        }
    }
}

@Observable
final class PlayerModel {
    let player = AVPlayer()
    private let api: PlexAPI
    private let item: PlexItem
    private var session = UUID().uuidString
    private var timeObserver: Any?
    private var stopped = false
    /// Set once a track was changed: Plex then builds the stream instead of serving the file.
    private var forceStream = false

    let audioTracks: [PlexStream]
    let subtitleTracks: [PlexStream]
    private(set) var selectedAudio: Int?
    private(set) var selectedSubtitle: Int?
    private(set) var isRestarting = false

    var hasTrackChoices: Bool { audioTracks.count > 1 || !subtitleTracks.isEmpty }
    private var partID: Int? { item.media?.first?.parts?.first?.id }

    init(api: PlexAPI, item: PlexItem, startOffset: Int) throws {
        self.api = api
        self.item = item
        let streams = item.media?.first?.parts?.first?.streams ?? []
        audioTracks = streams.filter(\.isAudio)
        subtitleTracks = streams.filter(\.isSubtitle)
        selectedAudio = audioTracks.first { $0.selected == true }?.id ?? audioTracks.first?.id
        selectedSubtitle = subtitleTracks.first { $0.selected == true }?.id
        forceStream = selectedSubtitle != nil
        try load(at: startOffset)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(state: self?.player.rate == 0 ? "paused" : "playing") }
        }
    }

    private func load(at offset: Int) throws {
        guard let url = api.streamURL(for: item, session: session, forceStream: forceStream,
                                      burnSubtitles: selectedSubtitle != nil) else {
            throw ServiceError.invalidResponse(.plex)
        }
        // HLS segment requests carry no token in their URLs: send it as a header on every request.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["X-Plex-Token": api.connection.secret]])
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if offset > 0 {
            player.seek(to: CMTime(value: CMTimeValue(offset), timescale: 1000))
        }
        player.play()
    }

    func selectAudio(_ id: Int?) {
        guard let id, id != selectedAudio else { return }
        selectedAudio = id
        restart { try await $0.select(part: $1, audio: id) }
    }

    func selectSubtitle(_ id: Int?) {
        guard id != selectedSubtitle else { return }
        selectedSubtitle = id
        restart { try await $0.select(part: $1, subtitle: id ?? 0) }
    }

    /// Saves the choice in Plex, then reopens the stream where it was.
    private func restart(_ change: @escaping (PlexAPI, Int) async throws -> Void) {
        guard let partID else { return }
        let position = currentMilliseconds
        let oldSession = session
        isRestarting = true
        player.pause()
        Task {
            defer { isRestarting = false }
            try? await change(api, partID)
            await api.stopTranscode(session: oldSession)
            session = UUID().uuidString
            forceStream = true
            try? load(at: position)
        }
    }

    var currentMilliseconds: Int {
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
