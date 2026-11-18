import Foundation
import Combine
import Security

struct Device: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var localHost = ""
    var tailscaleHost = ""
    var username = "pi"
    var port = 22
    var addressDefaultsVersion: Int? = 1
    var authentication: Authentication? = .phoneKey
    var authenticationMode: Authentication { authentication ?? .phoneKey }
    func host(for route: Route) -> String { route == .local ? localHost : tailscaleHost }
    // Public distribution contains no personal host addresses or credentials.
    static let defaults = [Device(name: "Pi Zero"), Device(name: "Pi 5"), Device(name: "Pi 4")]


    /// Upgrade only empty addresses in older profiles, preserving IDs and their Keychain passwords.
    func applyingAddressDefaults() -> Device {
        guard addressDefaultsVersion == nil else { return self }
        var updated = self
        let normalizedName = name.lowercased().filter { !$0.isWhitespace }
        if let template = Self.defaults.first(where: { $0.name.lowercased().filter { !$0.isWhitespace } == normalizedName }) {
            let wasUnconfigured = localHost.isEmpty && tailscaleHost.isEmpty
            if updated.localHost.isEmpty { updated.localHost = template.localHost }
            if updated.tailscaleHost.isEmpty { updated.tailscaleHost = template.tailscaleHost }
            if wasUnconfigured && updated.username == "pi" { updated.username = template.username }
        }
        updated.addressDefaultsVersion = 1
        return updated
    }
}

enum Authentication: String, CaseIterable, Identifiable, Codable {
    case phoneKey = "iPhone-Schlüssel · Face ID", password = "Passwort"
    var id: String { rawValue }
}

enum Route: String, CaseIterable, Identifiable {
    case local = "Lokal", tailscale = "Tailscale"
    var id: String { rawValue }
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [Device]
    @Published var error: String?
    private let url: URL

    init(storageURL: URL = URL.documentsDirectory.appending(path: "devices.json")) {
        url = storageURL
        do {
            let saved = try JSONDecoder().decode([Device].self, from: Data(contentsOf: url))
            devices = saved.map { $0.applyingAddressDefaults() }
            if devices != saved {
                do { try persist(devices) }
                catch { self.error = "Die Standardadressen konnten nicht gespeichert werden: \(error.localizedDescription)" }
            }
        } catch {
            devices = Device.defaults
            if FileManager.default.fileExists(atPath: url.path) {
                self.error = "Die gespeicherten Geräte konnten nicht gelesen werden: \(error.localizedDescription)"
            }
        }
    }

    func save(_ device: Device, password: String) throws {
        var updated = devices
        if let index = updated.firstIndex(where: { $0.id == device.id }) { updated[index] = device }
        else { updated.append(device) }
        try Keychain.save(password, account: device.id.uuidString)
        try persist(updated)
        devices = updated
    }

    func delete(_ device: Device) {
        do {
            let updated = devices.filter { $0.id != device.id }
            try persist(updated)
            devices = updated
            try Keychain.delete(account: device.id.uuidString)
        } catch { self.error = error.localizedDescription }
    }

    private func persist(_ devices: [Device]) throws {
        try JSONEncoder().encode(devices).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

enum Keychain {
    static let service = "de.michaelhein.SSHClient.password"
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func load(account: String) throws -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return value
    }
    static func save(_ value: String, account: String) throws {
        if value.isEmpty { try delete(account: account); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q.merge(attributes) { _, new in new }
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    static func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Schlüsselbund: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))" }
}

/// Removes only a single complete Markdown code fence. Shell syntax and indentation stay intact.
enum CommandText {
    static func removingFence(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), first < last,
              lines[first].hasPrefix("```"), lines[last].trimmingCharacters(in: .whitespaces) == "```",
              !lines[(first + 1)..<last].contains(where: { $0.hasPrefix("```") }) else { return normalized }
        return lines[(first + 1)..<last].joined(separator: "\n")
    }
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t" || $0.value == 127 }
    }
}
