import Foundation
import Combine
import Citadel
import NIOCore
import NIOSSH
import CryptoKit

struct HostTrust: Identifiable {
    let id = UUID()
    let endpoint: String
    let key: String
    let previousKey: String?
    var hostKeyFile: String {
        let algorithm = key.split(separator: " ").first.map(String.init) ?? ""
        if algorithm == "ssh-rsa" { return "rsa" }
        if algorithm.hasPrefix("ecdsa-") { return "ecdsa" }
        return "ed25519"
    }
    var fingerprint: String {
        let parts = key.split(separator: " ")
        guard parts.count > 1, let data = Data(base64Encoded: String(parts[1])) else { return key }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// The handshake stops before authentication if the server key is unknown or changed.
enum HostKeyError: Error { case untrusted }

final class HostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let trusted: String?
    private let lock = NSLock()
    private var captured: String?
    var receivedKey: String? { lock.lock(); defer { lock.unlock() }; return captured }
    init(trusted: String?) { self.trusted = trusted }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        lock.lock(); captured = key; lock.unlock()
        if key == trusted { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(HostKeyError.untrusted) }
    }
}

@MainActor
final class SSHSession: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected }
    @Published var status = Status.disconnected
    @Published var error: String?
    @Published var trust: HostTrust?
    @Published var draft = ""
    @Published var history: [String] = []
    @Published var sending = false
    @Published var authenticationBanner = ""
    @Published var authenticationURL: URL?
    private let identityLoader: () async throws -> Data
    init(identityLoader: @escaping () async throws -> Data = { try await PhoneIdentity.unlock() }) {
        self.identityLoader = identityLoader
    }
    var receive: (([UInt8]) -> Void)?
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var inputTail: Task<Void, Never>?
    private var cols = 80
    private var rows = 24
    private var pendingConnection: (Device, Route)?
    private var trustedKeys: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "trustedHostKeys") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "trustedHostKeys") }
    }

    func connect(_ device: Device, route: Route) {
        guard status == .disconnected else { return }
        error = nil
        let host = device.host(for: route).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { error = "Bitte zuerst die \(route.rawValue)-Adresse in den Geräteeinstellungen eintragen."; return }
        authenticationBanner = ""
        authenticationURL = nil
        status = .connecting
        let token = UUID()
        generation = token
        let endpoint = "[\(host.lowercased())]:\(device.port)"
        let known = trustedKeys[endpoint]
        let validator = HostValidator(trusted: known)
        pendingConnection = (device, route)
        task = Task {
            var opened: SSHClient?
            do {
                let authentication: SSHAuthenticationMethod
                if device.authenticationMode == .phoneKey {
                    let rawKey = try await identityLoader()
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    authentication = .custom(try PhoneKeyAuthentication(username: device.username, rawKey: rawKey))
                } else {
                    let password = try Keychain.load(account: device.id.uuidString)
                    guard !password.isEmpty else { throw MissingPassword() }
                    authentication = .passwordBased(username: device.username, password: password)
                }
                let bannerHandler = AuthenticationBannerHandler { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.authenticationBanner += message
                        if let match = message.range(of: "https://login\\.tailscale\\.com/a/[A-Za-z0-9]+", options: .regularExpression) {
                            self.authenticationURL = URL(string: String(message[match]))
                        }
                    }
                }
                let connection = try await SSHClient.connect(host: host, port: device.port,
                    authenticationMethod: authentication, hostKeyValidator: .custom(validator), reconnect: .never,
                    channelHandlers: [bannerHandler], connectTimeout: .seconds(15))
                opened = connection
                guard generation == token, !Task.isCancelled else { try? await connection.close(); return }
                client = connection
                // Reset modes (for example an old alternate screen) before a fresh shell.
                receive?(Array("\u{1b}c".utf8))
                try await connection.withPTY(.init(wantReply: true, term: "xterm-256color",
                    terminalCharacterWidth: cols, terminalRowHeight: rows,
                    terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { output, input in
                    guard self.generation == token else { return }
                    self.writer = input
                    self.status = .connected
                    self.authenticationURL = nil
                    for try await part in output {
                        try Task.checkCancellation()
                        guard self.generation == token else { break }
                        switch part {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.receive?(Array(buffer.readableBytesView))
                        }
                    }
                }
            } catch {
                if generation == token, !Task.isCancelled {
                    if let key = validator.receivedKey, key != known {
                        trust = HostTrust(endpoint: endpoint, key: key, previousKey: known)
                    } else {
                        self.error = "SSH-Verbindung: \(error.localizedDescription)\nPrüfe Adresse, Benutzer, Passwort und Erreichbarkeit. Bei Tailscale muss das VPN auf dem iPhone aktiv sein."
                    }
                }
            }
            if let opened { try? await opened.close() }
            if generation == token {
                writer = nil; client = nil; status = .disconnected
            }
        }
    }

    func acceptHost() {
        guard let trust, let (device, route) = pendingConnection else { return }
        trustedKeys[trust.endpoint] = trust.key
        self.trust = nil
        connect(device, route: route)
    }

    func disconnect() {
        generation = UUID()
        task?.cancel(); task = nil
        inputTail?.cancel(); inputTail = nil
        writer = nil
        let old = client
        client = nil
        status = .disconnected
        sending = false
        trust = nil
        authenticationURL = nil
        Task { try? await old?.close() }
    }

    func resize(cols: Int, rows: Int) {
        self.cols = max(cols, 1); self.rows = max(rows, 1)
        guard let writer else { return }
        Task { try? await writer.changeSize(cols: max(cols, 1), rows: max(rows, 1), pixelWidth: 0, pixelHeight: 0) }
    }

    /// Queue all writes so fast keystrokes and multi-packet scripts cannot overtake one another.
    func send(_ bytes: [UInt8], completion: (() -> Void)? = nil) {
        guard let writer, status == .connected else { return }
        let previous = inputTail
        let token = generation
        inputTail = Task {
            await previous?.value
            guard !Task.isCancelled, generation == token else { return }
            do {
                // Limit packet size; do not split/reinterpret UTF-8 on the output path.
                for start in stride(from: 0, to: bytes.count, by: 4096) {
                    try Task.checkCancellation()
                    try await writer.write(ByteBuffer(bytes: bytes[start..<min(start + 4096, bytes.count)]))
                }
                if generation == token { completion?() }
            } catch {
                if generation == token, !Task.isCancelled {
                    self.error = "Senden fehlgeschlagen: \(error.localizedDescription)"
                    self.disconnect()
                }
            }
        }
    }

    func sendDraft() {
        guard !sending, status == .connected, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let command = CommandText.removingFence(draft)
        guard !CommandText.containsControlCharacters(command) else {
            error = "Der Text enthält unsichtbare Steuerzeichen. Bitte entferne sie vor dem Senden."; return
        }
        guard let draftSender else { error = "Das Terminal ist noch nicht bereit."; return }
        sending = true
        // A single paste event prevents bash/readline from interpreting each line as keystrokes.
        // Bracketed paste is negotiated by the terminal, see TerminalBridge.sendDraft.
        draftSender(command) { [weak self] in
            guard let self else { return }
            if self.history.first != command { self.history.insert(command, at: 0) }
            self.history = Array(self.history.prefix(30))
            self.sending = false
        }
    }
    var draftSender: ((String, @escaping () -> Void) -> Void)?
    func stage(_ text: String) {
        let incoming = CommandText.removingFence(text)
        if draft.isEmpty { draft = incoming }
        else { draft += (draft.hasSuffix("\n") ? "" : "\n") + incoming }
    }
}

struct MissingPassword: LocalizedError {
    var errorDescription: String? { "Bitte das SSH-Passwort hinterlegen oder die Anmeldung mit iPhone-Schlüssel wählen." }
}
