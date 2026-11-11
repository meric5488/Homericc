import SwiftUI

struct SettingsView: View {
    @Environment(ServiceStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ServiceKind.allCases) { kind in
                        NavigationLink(value: kind) {
                            ServiceRow(kind: kind, isConfigured: store.isConfigured(kind))
                        }
                    }
                } header: {
                    Text("Services")
                } footer: {
                    Text("Pour chaque service, Homericc essaie d'abord l'adresse locale, puis l'adresse distante si tu n'es pas chez toi.")
                }

                if store.isConfigured(.prowlarr) {
                    Section("Outils") {
                        NavigationLink {
                            ProwlarrView()
                        } label: {
                            Label("Indexeurs Prowlarr", systemImage: "magnifyingglass")
                        }
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Link(destination: URL(string: "https://github.com/meric5488/Homericc")!) {
                        Label("Code source sur GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .navigationTitle("Réglages")
            .navigationDestination(for: ServiceKind.self) { kind in
                ServiceEditView(kind: kind)
            }
        }
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
    @Environment(\.dismiss) private var dismiss

    @State private var config: ServiceConfig
    @State private var secret = ""
    @State private var test: Loadable<ServiceStatus> = .idle
    @State private var confirmRemoval = false

    init(kind: ServiceKind) {
        self.kind = kind
        _config = State(initialValue: ServiceConfig(kind: kind))
    }

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.10:\(kind.defaultPort)", text: $config.localURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Adresse locale")
            } footer: {
                Text("L'adresse sur ton réseau, avec le port. Laisse vide si tu n'en as pas.")
            }

            Section {
                TextField("https://\(kind.rawValue).mondomaine.fr", text: $config.remoteURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Adresse distante")
            } footer: {
                Text("Utilisée quand l'adresse locale ne répond pas : nom de domaine, reverse proxy ou adresse Tailscale.")
            }

            Section {
                switch kind.credential {
                case .apiKey, .token:
                    SecureField(kind.credential == .token ? "Jeton Plex" : "Clé API", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .login:
                    TextField("Nom d'utilisateur", text: $config.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
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
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Text("Tester la connexion")
                        Spacer()
                        testResult
                    }
                }
                .disabled(config.candidateURLs.isEmpty)
            }

            if store.configs[kind] != nil {
                Section {
                    Button("Supprimer ce service", role: .destructive) { confirmRemoval = true }
                }
            }
        }
        .navigationTitle(kind.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer") {
                    store.save(config, secret: secret)
                    dismiss()
                }
                .disabled(config.candidateURLs.isEmpty)
            }
        }
        .confirmationDialog("Supprimer \(kind.name) ?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                store.remove(kind)
                dismiss()
            }
        }
        .onAppear {
            config = store.config(for: kind)
            secret = store.secret(for: kind)
        }
        .onChange(of: config) { test = .idle }
        .onChange(of: secret) { test = .idle }
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
