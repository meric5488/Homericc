import SwiftUI

/// The menu bar panel: a glance at downloads, requests and playback, and a way back to the window.
struct MenuBarView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(ServiceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Homericc").font(.headline)
                Spacer()
                if let transfer = monitor.transfer {
                    Text("↓ \(transfer.dl_info_speed.speed)  ↑ \(transfer.up_info_speed.speed)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !monitor.offline.isEmpty {
                Label("\(monitor.offline.map(\.name).sorted().formatted(.list(type: .and))) hors ligne",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            let active = monitor.torrents.filter { !$0.isComplete }
            if store.isConfigured(.qbittorrent) {
                section("Téléchargements", count: active.count, item: .downloads) {
                    if active.isEmpty {
                        Text("Rien en cours").foregroundStyle(.secondary)
                    }
                    ForEach(active.prefix(4)) { torrent in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(torrent.name).lineLimit(1)
                            ProgressView(value: torrent.progress)
                                .tint(torrent.isPaused ? .secondary : .accentColor)
                        }
                    }
                }
            }

            if store.isConfigured(.seerr) {
                section("Demandes en attente", count: monitor.pendingRequests.count, item: .requests) {
                    if monitor.pendingRequests.isEmpty {
                        Text("Aucune").foregroundStyle(.secondary)
                    }
                }
            }

            if !monitor.sessions.isEmpty {
                section("En lecture sur Plex", count: monitor.sessions.count, item: .home) {
                    ForEach(monitor.sessions.prefix(3)) { item in
                        Text("\(item.headline) · \(item.user?.title ?? "")").lineLimit(1)
                    }
                }
            }

            Divider()
            HStack {
                Button("Ouvrir Homericc") { open(.home) }
                    .keyboardShortcut("o")
                Spacer()
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Réglages")
                .accessibilityLabel("Réglages")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quitter Homericc")
                .accessibilityLabel("Quitter")
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 320)
        .onAppear { monitor.refreshNow() }
    }

    private func section<Content: View>(_ title: String, count: Int, item: SidebarItem,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open(item) } label: {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .background(.fill.secondary, in: .capsule)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            content()
        }
    }

    private func open(_ item: SidebarItem) {
        navigation.selection = item
        NSApp.activate()
        openWindow(id: "main")
    }
}
