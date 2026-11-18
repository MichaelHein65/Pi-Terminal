import SwiftUI
import UniformTypeIdentifiers
import SafariServices

struct ContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var editing: Device?
    @State private var deleting: Device?
    @State private var showIdentity = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("DEINE GERÄTE. DEINE SHELL.", systemImage: "network")
                            .font(.caption.weight(.bold)).tracking(1).foregroundStyle(.teal)
                        Text("Eine Verbindung.\nAlle Möglichkeiten.")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("Erreiche deine Pis im Heimnetz oder über Tailscale. Befehle aus deiner LLM ziehst du direkt in den Editor.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    ForEach(store.devices) { device in
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top) {
                                Image(systemName: "server.rack").font(.title2).foregroundStyle(.teal)
                                    .frame(width: 50, height: 50).background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(device.name).font(.title3.bold())
                                    Text(device.localHost.isEmpty && device.tailscaleHost.isEmpty ? "Noch nicht eingerichtet" : "\(device.username) · Port \(device.port)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { editing = device } label: { Image(systemName: "slider.horizontal.3").padding(10) }
                                    .accessibilityLabel("\(device.name) bearbeiten")
                            }
                            HStack {
                                addressLabel("wifi", device.localHost, fallback: "Lokale Adresse fehlt")
                                Spacer(minLength: 5)
                                addressLabel("point.3.connected.trianglepath.dotted", device.tailscaleHost, fallback: "Tailscale-Adresse fehlt")
                            }.font(.caption2).foregroundStyle(.secondary)
                            if device.localHost.isEmpty && device.tailscaleHost.isEmpty {
                                Button { editing = device } label: { Label("Gerät einrichten", systemImage: "plus.circle").frame(maxWidth: .infinity) }
                                    .buttonStyle(.borderedProminent).controlSize(.large)
                            } else {
                                NavigationLink { SessionView(device: device) } label: {
                                    Label("Terminal öffnen", systemImage: "terminal").frame(maxWidth: .infinity)
                                }.buttonStyle(.borderedProminent).controlSize(.large)
                            }
                        }
                        .padding(18).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                        .contextMenu {
                            Button("Bearbeiten", systemImage: "pencil") { editing = device }
                            Button("Löschen", systemImage: "trash", role: .destructive) { deleting = device }
                        }
                    }
                    Label("Tailscale auf dem iPhone aktivieren und die 100.x-Adresse oder den MagicDNS-Namen hinterlegen. Die App nutzt den SSH-Dienst deines Geräts.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Pi Terminal")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("iPhone-Schlüssel", systemImage: "key.fill") { showIdentity = true }
                    Button("Gerät hinzufügen", systemImage: "plus") { editing = Device() }
                }
            }
            .sheet(isPresented: $showIdentity) { PhoneIdentityView() }
            .sheet(item: $editing) { DeviceEditor(device: $0) }
            .alert("Gerät löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Löschen", role: .destructive) { if let deleting { store.delete(deleting) }; deleting = nil }
                Button("Abbrechen", role: .cancel) { deleting = nil }
            } message: { Text("Das gespeicherte Gerät und sein Passwort werden entfernt.") }
            .alert("Pi Terminal", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
        }
    }
    private func addressLabel(_ icon: String, _ address: String, fallback: String) -> some View {
        Label(address.isEmpty ? fallback : address, systemImage: icon).lineLimit(1)
    }
}

struct DeviceEditor: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State var device: Device
    @State private var password = ""
    @State private var port = "22"
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Gerät") {
                    TextField("Name, z. B. Pi 5", text: $device.name)
                    LabeledContent("Benutzer") { TextField("SSH-Benutzer", text: $device.username).textContentType(.username).multilineTextAlignment(.trailing) }
                    LabeledContent("SSH-Port") { TextField("22", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                }
                Section {
                    TextField("z. B. pizero.local oder 192.168.1.20", text: $device.localHost)
                        .keyboardType(.URL)
                } header: { Label("Lokales Netzwerk", systemImage: "wifi") }
                Section {
                    TextField("100.x.x.x oder MagicDNS-Name", text: $device.tailscaleHost).keyboardType(.URL)
                } header: { Label("Tailscale", systemImage: "network") }
                footer: { Text("Mindestens eine Adresse eintragen. Nur den Hostnamen oder die IP verwenden, ohne ssh://, Benutzer oder Port. Bei IPv6 keine eckigen Klammern verwenden.") }
                Section {
                    Picker("Anmeldung", selection: Binding(get: { device.authenticationMode }, set: { device.authentication = $0 })) {
                        ForEach(Authentication.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if device.authenticationMode == .password {
                        SecureField("SSH-Passwort", text: $password).textContentType(.password)
                    } else {
                        Label("Face ID gibt deinen SSH-Schlüssel frei.", systemImage: "faceid")
                        Text("Der private Schlüssel bleibt auf diesem iPhone. Sein öffentlicher Teil muss einmal auf dem Pi hinterlegt sein.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Anmeldung") }
                footer: { Text("Für Tailscale SSH wird nach Face ID deine Tailscale-Identität verwendet. Eine zusätzliche Tailscale-Freigabe erscheint bei Bedarf als Link.") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(device.name.isEmpty ? "Neues Gerät" : device.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern", action: save).bold().disabled(!loaded) }
            }
            .onAppear {
                guard !loaded else { return }
                port = String(device.port)
                do { password = try Keychain.load(account: device.id.uuidString); loaded = true }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private func save() {
        device.name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        device.username = device.username.trimmingCharacters(in: .whitespacesAndNewlines)
        device.localHost = device.localHost.trimmingCharacters(in: .whitespacesAndNewlines)
        device.tailscaleHost = device.tailscaleHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !device.name.isEmpty, !device.username.isEmpty, let portNumber = Int(port), (1...65535).contains(portNumber),
              !device.localHost.isEmpty || !device.tailscaleHost.isEmpty else {
            error = "Bitte Name, Benutzer, mindestens eine Adresse und einen gültigen Port (1–65535) angeben."; return
        }
        for host in [device.localHost, device.tailscaleHost] where !host.isEmpty {
            if host.contains(where: { $0.isWhitespace }) || host.contains("/") || host.contains("@") {
                error = "Bitte nur einen Hostnamen oder eine IP-Adresse eingeben."; return
            }
        }
        device.port = portNumber
        do { try store.save(device, password: password); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct SessionView: View {
    let device: Device
    @StateObject private var session = SSHSession()
    init(device: Device) { self.device = device }
    init(device: Device, session: SSHSession) {
        self.device = device
        self._session = StateObject(wrappedValue: session)
    }
    @State private var route = Route.local
    @State private var showHistory = false
    @State private var isDropTarget = false
    @State private var showAuthentication = false
    @FocusState private var editing: Bool
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Picker("Verbindungsweg", selection: $route) {
                        ForEach(Route.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).disabled(session.status != .disconnected)
                    Button(action: toggleConnection) {
                        if session.status == .connecting { ProgressView().frame(width: 24) }
                        else { Image(systemName: session.status == .connected ? "stop.fill" : "bolt.fill") }
                    }.buttonStyle(.borderedProminent)
                        .tint(session.status == .disconnected ? .teal : .orange)
                        .accessibilityLabel(session.status == .disconnected ? "Verbinden" : "Verbindung trennen")
                }
                HStack(spacing: 6) {
                    Circle().fill(session.status == .connected ? .green : .secondary).frame(width: 6, height: 6)
                    Text(statusText).font(.caption.weight(.medium))
                    Spacer()
                    Text(device.host(for: route).isEmpty ? "Adresse fehlt" : "\(device.username)@\(device.host(for: route))")
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            }.padding(14)
            if session.status == .connecting, let url = session.authenticationURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tailscale benötigt eine zusätzliche Freigabe.").font(.subheadline)
                    Button("Bei Tailscale bestätigen", systemImage: "person.badge.shield.checkmark") { showAuthentication = true }
                    Text(url.absoluteString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.1))
            }
            TerminalBridge(session: session)
                .accessibilityLabel("SSH-Terminal")
                .overlay(alignment: .topTrailing) {
                    if session.status == .disconnected {
                        Text("Nicht verbunden").font(.caption2).foregroundStyle(.white.opacity(0.7))
                            .padding(6).background(.black.opacity(0.7), in: Capsule()).padding(8).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 0) {
                key("Esc", "\u{1b}")
                key("Tab", "\t")
                key("↑", "\u{1b}[A")
                key("↓", "\u{1b}[B")
                key("Strg-C", "\u{03}")
                key("Enter", "\r")
            }.font(.caption.monospaced()).padding(.vertical, 6).background(Color(.secondarySystemBackground))
            editor
        }
        .navigationTitle(device.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Verlauf", systemImage: "clock.arrow.circlepath") { showHistory = true }
        } }
        .onAppear { route = device.localHost.isEmpty ? .tailscale : .local }
        .onDisappear { session.disconnect() }
        .alert("SSH", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .sheet(item: $session.trust) { trust in trustView(trust).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showHistory) { historyView }
        .sheet(isPresented: $showAuthentication) {
            if let url = session.authenticationURL { AuthenticationBrowser(url: url).ignoresSafeArea() }
        }
        .onChange(of: session.status) { _, status in if status == .connected { showAuthentication = false } }
    }
    private var statusText: String {
        switch session.status {
        case .connected: return "Verbunden"
        case .connecting: return "Verbindet …"
        case .disconnected: return "Bereit zum Verbinden"
        }
    }
    private func toggleConnection() {
        editing = false
        if session.status == .disconnected { session.connect(device, route: route) }
        else { session.disconnect() }
    }
    private func key(_ title: String, _ value: String) -> some View {
        Button(title) { editing = false; session.send(Array(value.utf8)) }
            .frame(maxWidth: .infinity).padding(.vertical, 8).disabled(session.status != .connected)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Befehlseditor", systemImage: "text.alignleft").font(.subheadline.bold())
                Spacer()
                PasteButton(payloadType: String.self) { values in
                    session.stage(values.joined(separator: "\n"))
                }.labelStyle(.iconOnly).buttonBorderShape(.capsule)
                Button("Leeren", systemImage: "trash") { session.draft = "" }.labelStyle(.iconOnly)
                    .disabled(session.draft.isEmpty)
            }
            TextEditor(text: $session.draft)
                .font(.system(size: 13, design: .monospaced)).focused($editing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .frame(height: editing ? 100 : 80)
                .scrollContentBackground(.hidden)
                .padding(4).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Befehl oder mehrzeiliges Skript")
            HStack(spacing: 12) {
                Label(isDropTarget ? "Hier ablegen" : "Text hierher ziehen", systemImage: "arrow.down.doc")
                    .font(.caption).foregroundStyle(isDropTarget ? .teal : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
                    .background(isDropTarget ? .teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .dropDestination(for: String.self) { items, _ in
                        guard !items.isEmpty else { return false }
                        session.stage(items.joined(separator: "\n")); return true
                    } isTargeted: { isDropTarget = $0 }
                Button {
                    editing = false
                    session.sendDraft()
                } label: {
                    Label(session.sending ? "Sendet …" : "Senden", systemImage: "paperplane.fill")
                }.buttonStyle(.borderedProminent)
                    .disabled(session.status != .connected || session.sending || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Mehrzeilige Skripte werden gemeinsam gesendet. Ausführung mit „Senden“.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).background(Color(.systemBackground))
    }
    private func trustView(_ trust: HostTrust) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(trust.previousKey == nil ? "Neues Gerät prüfen" : "Server-Schlüssel geändert", systemImage: "lock.shield")
                        .font(.title2.bold())
                    Text(trust.endpoint).font(.subheadline.monospaced())
                    Text(trust.previousKey == nil ? "Vergleiche den Fingerabdruck mit deinem Pi, bevor du diesem Gerät vertraust." : "Dieser Schlüssel weicht vom gespeicherten Schlüssel ab. Vertraue ihm nur, wenn du die Änderung am Pi nachvollziehen kannst.")
                    Text(trust.fingerprint).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("Auf dem Pi prüfen: sudo ssh-keygen -lf /etc/ssh/ssh_host_\(trust.hostKeyFile)_key.pub")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button(trust.previousKey == nil ? "Vertrauen und verbinden" : "Neuen Schlüssel vertrauen") { session.acceptHost() }
                        .buttonStyle(.borderedProminent)
                    Button("Abbrechen", role: .cancel) { session.trust = nil }
                }.padding(24)
            }.navigationTitle("Server-Identität").navigationBarTitleDisplayMode(.inline)
        }
    }
    private var historyView: some View {
        NavigationStack {
            List {
                if session.history.isEmpty { Text("Noch keine Befehle in dieser Sitzung gesendet.").foregroundStyle(.secondary) }
                ForEach(Array(session.history.enumerated()), id: \.offset) { _, command in
                    Button {
                        session.draft = command
                        showHistory = false
                    } label: { Text(command).font(.footnote.monospaced()).lineLimit(6) }
                }
            }
            .navigationTitle("Befehlsverlauf")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { showHistory = false } }
                ToolbarItem(placement: .topBarTrailing) { Button("Leeren") { session.history = [] }.disabled(session.history.isEmpty) }
            }
            .safeAreaInset(edge: .bottom) { Text("Antippen übernimmt den Befehl in den Editor. Der Verlauf bleibt nur während dieser Sitzung erhalten.").font(.caption).foregroundStyle(.secondary).padding().background(.bar) }
        }
    }
}

struct AuthenticationBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct PhoneIdentityView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var publicKey = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Dein Schlüssel wird mit Face ID entsperrt.", systemImage: "faceid")
                    Text("Der private Schlüssel bleibt auf diesem iPhone. Für den Zugriff auf ein weiteres Gerät wird nur der öffentliche Schlüssel dort hinterlegt.")
                }
                if !publicKey.isEmpty {
                    Section("Öffentlicher SSH-Schlüssel") {
                        Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                        ShareLink(item: publicKey) { Label("Öffentlichen Schlüssel teilen", systemImage: "square.and.arrow.up") }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("iPhone-Schlüssel").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onAppear {
                do { publicKey = try PhoneIdentity.prepare() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
