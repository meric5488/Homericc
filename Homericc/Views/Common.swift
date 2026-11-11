import SwiftUI

extension Int64 {
    var bytes: String { formatted(.byteCount(style: .file)) }
    var speed: String { "\(formatted(.byteCount(style: .file)))/s" }
}

/// Async loading state for a screen.
enum Loadable<Value> {
    case idle, loading, loaded(Value), failed(String)

    var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }
}

/// A poster with a neutral placeholder, sized by its container.
struct PosterImage: View {
    let url: URL?
    var symbol = "photo"
    var aspectRatio: CGFloat = 2 / 3

    var body: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: symbol)
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

/// Shown in place of a screen whose service isn't set up yet.
struct NotConfiguredView: View {
    let kinds: [ServiceKind]
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ContentUnavailableView {
            Label("\(kinds.map(\.name).formatted(.list(type: .or))) à configurer", systemImage: kinds.first?.symbol ?? "gear")
        } description: {
            Text("Ajoute l'adresse et la clé du serveur dans les réglages.")
        } actions: {
            Button("Ouvrir les réglages…") {
                navigation.settingsSelection = kinds.first.map(SettingsPage.service)
                openSettings()
            }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ErrorView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Connexion impossible", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Réessayer") { Task { await retry() } }
        }
    }
}

/// Runs a mutating call and surfaces its error as an alert.
@Observable
final class ActionRunner {
    var errorMessage: String?
    var isRunning = false

    func run(_ action: @escaping () async throws -> Void) {
        Task {
            isRunning = true
            defer { isRunning = false }
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension View {
    func errorAlert(_ runner: ActionRunner) -> some View {
        alert("Action impossible", isPresented: Binding(
            get: { runner.errorMessage != nil },
            set: { if !$0 { runner.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(runner.errorMessage ?? "")
        }
    }
}
