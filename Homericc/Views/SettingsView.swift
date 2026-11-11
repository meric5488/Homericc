import SwiftUI

enum SettingsPage: Hashable {
    case general
    case service(ServiceKind)
}

/// The Settings window (⌘,): general options, then one page per service.
struct SettingsView: View {
    @Environment(ServiceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.settingsSelection) {
                Label("Général", systemImage: "gearshape")
                    .tag(SettingsPage.general)
                Section("Services") {
                    ForEach(ServiceKind.allCases) { kind in
                        ServiceRow(kind: kind, isConfigured: store.isConfigured(kind))
                            .tag(SettingsPage.service(kind))
                    }
                }
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch navigation.settingsSelection {
            case .general?:
                GeneralSettingsView()
            case .service(let kind)?:
                ServiceEditView(kind: kind)
                    .id(kind)
            case nil:
                EmptyView()
            }
        }
        .frame(width: 720, height: 560)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Afficher dans la barre des menus", isOn: $settings.showInMenuBar)
                Toggle("Afficher dans le Dock", isOn: $settings.showInDock)
                    .disabled(!settings.showInMenuBar)
            } header: {
                Text("Présence")
            } footer: {
                Text("Dans la barre des menus, Homericc reste ouvert quand tu fermes sa fenêtre et continue de surveiller tes serveurs. Sans la barre des menus, l'icône du Dock reste affichée.")
            }
            Section {
                Toggle("Téléchargement terminé", isOn: $settings.notifyDownloads)
                Toggle("Nouvelle demande Seerr", isOn: $settings.notifyRequests)
                Toggle("Service hors ligne", isOn: $settings.notifyOffline)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Les serveurs sont vérifiés toutes les 30 secondes tant que Homericc est ouvert.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Général")
        .onChange(of: settings.showInDock) { AppDelegate.applyDockPolicy() }
        .onChange(of: settings.showInMenuBar) { AppDelegate.applyDockPolicy() }
    }
}

private struct ServiceRow: View {
    let kind: ServiceKind
    let isConfigured: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(kind.name)
                Text(isConfigured ? kind.role : "Non configuré")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: kind.symbol)
        }
    }
}

struct ServiceEditView: View {
    let kind: ServiceKind
    @Environment(ServiceStore.self) private var store

    @State private var config: ServiceConfig
    @State private var secret = ""
    @State private var test: Loadable<ServiceStatus> = .idle
    @State private var confirmRemoval = false
    @State private var saved = false

    init(kind: ServiceKind) {
        self.kind = kind
        _config = State(initialValue: ServiceConfig(kind: kind))
    }

    var body: some View {
        Form {
            Section {
                TextField("Adresse locale", text: $config.localURL,
                          prompt: Text(verbatim: "http://192.168.1.10:\(kind.defaultPort)"))
                    .autocorrectionDisabled()
                TextField("Adresse distante", text: $config.remoteURL,
                          prompt: Text(verbatim: "https://\(kind.rawValue).mondomaine.fr"))
                    .autocorrectionDisabled()
            } header: {
                Text("Adresses")
            } footer: {
                Text("L'adresse locale (avec le port) est essayée en premier. L'adresse distante (nom de domaine, reverse proxy ou Tailscale) sert quand tu n'es pas chez toi. L'une des deux peut rester vide.")
            }

            Section {
                switch kind.credential {
                case .apiKey, .token:
                    SecureField(kind.credential == .token ? "Jeton Plex" : "Clé API", text: $secret)
                case .login:
                    TextField("Nom d'utilisateur", text: $config.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    SecureField("Mot de passe", text: $secret)
                        .textContentType(.password)
                }
            } header: {
                Text("Accès")
            } footer: {
                Text(credentialHelp)
            }

            Section {
                Toggle("Activé", isOn: $config.isEnabled)
            }

            Section {
                HStack {
                    if store.configs[kind] != nil {
                        Button("Supprimer…", role: .destructive) { confirmRemoval = true }
                    }
                    Spacer()
                    testResult
                    Button("Tester la connexion") { Task { await runTest() } }
                        .disabled(config.candidateURLs.isEmpty)
                    Button(saved ? "Enregistré" : "Enregistrer") {
                        store.save(config, secret: secret)
                        saved = true
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(config.candidateURLs.isEmpty || saved)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind.name)
        .confirmationDialog("Supprimer \(kind.name) ?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                store.remove(kind)
                config = ServiceConfig(kind: kind)
                secret = ""
            }
        }
        .onAppear {
            config = store.config(for: kind)
            secret = store.secret(for: kind)
        }
        .onChange(of: config) { test = .idle; saved = false }
        .onChange(of: secret) { test = .idle; saved = false }
    }

    @ViewBuilder private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView()
        case .loaded(let status):
            Label {
                Text(status.isRemote ? "OK (distant)" : "OK")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Échec")
        }
    }

    private var credentialHelp: String {
        if case .failed(let message) = test { return message }
        return switch kind {
        case .plex: "Jeton X-Plex-Token de ton compte : dans Plex Web, « Obtenir des infos » sur un média, puis « Afficher le XML » ; il est à la fin de l'adresse."
        case .qbittorrent: "Les identifiants de l'interface web de qBittorrent."
        case .seerr: "Dans Seerr : Paramètres > Général > Clé API."
        default: "Dans \(kind.name) : Settings > General > API Key."
        }
    }

    private func runTest() async {
        test = .loading
        ServiceConnection.invalidate()
        let connection = ServiceConnection.shared(for: config, secret: secret)
        do {
            test = .loaded(try await ServiceStatus.check(connection))
        } catch {
            test = .failed(error.localizedDescription)
        }
    }
}
