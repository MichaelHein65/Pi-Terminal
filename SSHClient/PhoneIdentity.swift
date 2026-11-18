import Foundation
import CryptoKit
import Security
import LocalAuthentication
import NIOSSH
import NIOCore

/// The private key is created on the iPhone and never exported from the iPhone.
enum PhoneIdentity {
    private static let service = "de.michaelhein.SSHClient.biometricIdentity"
    static let publicKeyURL = URL.documentsDirectory.appending(path: "iphone-ssh.pub")
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    @discardableResult
    static func prepare() throws -> String {
        var publicQuery = query("public")
        publicQuery[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(publicQuery as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let publicKey = String(data: data, encoding: .utf8) {
            try writePublicKey(publicKey)
            return publicKey
        }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let context = LAContext()
        var reason: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &reason) else {
            throw reason ?? IdentityError.biometricsUnavailable as NSError
        }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, &accessError) else {
            if let error = accessError?.takeRetainedValue() { throw error }
            throw IdentityError.biometricsUnavailable
        }
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = openSSHPublicKey(key.publicKey.rawRepresentation)
        var privateQuery = query("private")
        privateQuery[kSecValueData as String] = key.rawRepresentation
        privateQuery[kSecAttrAccessControl as String] = access
        let added = SecItemAdd(privateQuery as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        var publicItem = query("public")
        publicItem[kSecValueData as String] = Data(publicKey.utf8)
        publicItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let publicAdded = SecItemAdd(publicItem as CFDictionary, nil)
        guard publicAdded == errSecSuccess else {
            SecItemDelete(query("private") as CFDictionary)
            throw KeychainError(status: publicAdded)
        }
        try writePublicKey(publicKey)
        return publicKey
    }
    private static func writePublicKey(_ key: String) throws {
        try Data((key + "\n").utf8).write(to: publicKeyURL, options: [.atomic, .completeFileProtection])
    }
    static func openSSHPublicKey(_ raw: Data) -> String {
        var wire = Data()
        for item in [Data("ssh-ed25519".utf8), raw] {
            var size = UInt32(item.count).bigEndian
            withUnsafeBytes(of: &size) { wire.append(contentsOf: $0) }
            wire.append(item)
        }
        return "ssh-ed25519 " + wire.base64EncodedString() + " pi-terminal-iphone"
    }
    static func unlock() async throws -> Data {
        try await Task.detached {
            _ = try prepare()
            let context = LAContext()
            context.localizedFallbackTitle = ""
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "SSH-Verbindung mit deinem persönlichen iPhone-Schlüssel freigeben")
            guard accepted else { throw IdentityError.biometricsUnavailable }
            defer { context.invalidate() }
            var q = query("private")
            q[kSecReturnData as String] = true
            q[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
            return data
        }.value
    }
}

enum IdentityError: LocalizedError {
    case biometricsUnavailable, rejected
    var errorDescription: String? {
        switch self {
        case .biometricsUnavailable: return "Bitte Face ID und einen Gerätecode auf diesem iPhone einrichten. Der SSH-Schlüssel wird ausschließlich mit Biometrie entsperrt."
        case .rejected: return "Der Server hat die SSH-Anmeldung abgelehnt. Der öffentliche iPhone-Schlüssel muss auf dem Pi hinterlegt sein."
        }
    }
}

/// Tailscale SSH authenticates the VPN identity with `none`; OpenSSH uses the iPhone key.
final class PhoneKeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: NIOSSHPrivateKey
    private var attempt = 0
    init(username: String, rawKey: Data) throws {
        self.username = username
        key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey))
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        defer { attempt += 1 }
        if attempt == 0 {
            nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .none))
        } else if attempt == 1, availableMethods.contains(.publicKey) {
            nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
        } else { nextChallengePromise.fail(IdentityError.rejected) }
    }
}

final class AuthenticationBannerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let display: @Sendable (String) -> Void
    init(display: @escaping @Sendable (String) -> Void) { self.display = display }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let banner = event as? NIOUserAuthBannerEvent { display(banner.message) }
        context.fireUserInboundEventTriggered(event)
    }
}
