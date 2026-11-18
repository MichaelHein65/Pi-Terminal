import XCTest
import SwiftUI
@testable import SSHClient

final class SSHClientTests: XCTestCase {
    func testAddressDefaultsUpgradeKeepsIdentityAndCustomAddresses() throws {
        // Decode the previous app's actual storage shape, without a migration marker.
        let id = UUID()
        let legacy = Data("""
        [{"id":"\(id.uuidString)","name":"Pi 4","localHost":"","tailscaleHost":"100.1.2.3","username":"custom","port":2222}]
        """.utf8)
        let device = try JSONDecoder().decode([Device].self, from: legacy)[0]
        let updated = device.applyingAddressDefaults()
        XCTAssertEqual(updated.id, id)
        XCTAssertEqual(updated.localHost, Device.defaults[2].localHost)
        XCTAssertEqual(updated.tailscaleHost, "100.1.2.3")
        XCTAssertEqual(updated.username, "custom")
        XCTAssertEqual(updated.port, 2222)
        var intentionallyCleared = updated
        intentionallyCleared.localHost = ""
        XCTAssertEqual(intentionallyCleared.applyingAddressDefaults().localHost, "")
        var untouchedPlaceholder = device
        untouchedPlaceholder.tailscaleHost = ""
        untouchedPlaceholder.username = "pi"
        XCTAssertEqual(untouchedPlaceholder.applyingAddressDefaults().username, Device.defaults[2].username)
    }

    func testMarkdownScriptPreservesHeredocAndIndentation() {
        let source = "\n```bash\ncat <<'PY'\n  Grüße 🥧\nPY\n```\n"
        XCTAssertEqual(CommandText.removingFence(source), "cat <<'PY'\n  Grüße 🥧\nPY")
        XCTAssertEqual(CommandText.removingFence("printf 'a'\r\nprintf 'b'"), "printf 'a'\nprintf 'b'")
        let multiple = "```sh\npwd\n```\nText\n```sh\nls\n```"
        XCTAssertEqual(CommandText.removingFence(multiple), multiple)
    }
    func testRejectsTerminalControlInjectionButAllowsScripts() {
        XCTAssertTrue(CommandText.containsControlCharacters("echo x\u{1b}[201~\nrm"))
        XCTAssertTrue(CommandText.containsControlCharacters("\u{03}"))
        XCTAssertFalse(CommandText.containsControlCharacters("printf 'Grüße 🥧'\n\t pwd"))
    }
    func testKeychainRoundtripAndDeletion() throws {
        let account = "test-" + UUID().uuidString
        defer { try? Keychain.delete(account: account) }
        try Keychain.save("pässword 🥧", account: account)
        XCTAssertEqual(try Keychain.load(account: account), "pässword 🥧")
        try Keychain.save("changed", account: account)
        XCTAssertEqual(try Keychain.load(account: account), "changed")
        try Keychain.delete(account: account)
        XCTAssertEqual(try Keychain.load(account: account), "")
    }

    @MainActor
    func testSSHTrustPersistentShellUnicodeMultilineAndDisconnect() async throws {
        guard ProcessInfo.processInfo.environment["PI_TERMINAL_SSH_TEST"] == "1" else {
            throw XCTSkip("Start Scripts/ssh_fixture.py and use the SSHIntegration scheme to run the SSH integration test.")
        }
        let endpoint = "[127.0.0.1]:22222"
        let defaults = UserDefaults.standard
        let oldKeys = defaults.dictionary(forKey: "trustedHostKeys")
        var keys = oldKeys as? [String: String] ?? [:]
        keys.removeValue(forKey: endpoint)
        defaults.set(keys, forKey: "trustedHostKeys")
        var device = Device(name: "Fixture", localHost: "127.0.0.1", username: "fixture", port: 22222, authentication: .password)
        try Keychain.save("simulator-only", account: device.id.uuidString)
        let session = SSHSession(identityLoader: { Data(repeating: 7, count: 32) })
        defer {
            session.disconnect()
            defaults.set(oldKeys, forKey: "trustedHostKeys")
            try? Keychain.delete(account: device.id.uuidString)
        }
        // Exercise the actual UIKit terminal bridge, including the editor send path.
        let controller = UIHostingController(rootView: TerminalBridge(session: session))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await waitUntil { session.draftSender != nil }
        var received: [UInt8] = []
        let terminalReceive = session.receive
        session.receive = { terminalReceive?($0); received += $0 }
        session.connect(device, route: .local)
        try await waitUntil { session.trust != nil && session.status == .disconnected }
        XCTAssertNil(session.error)
        XCTAssertNil(session.trust?.previousKey)
        XCTAssertTrue(session.trust?.fingerprint.hasPrefix("SHA256:") == true)
        session.acceptHost()
        try await waitUntil { session.status == .connected }
        session.send(Array("cd /tmp\r".utf8))
        session.send(Array("printf '\\x47\\x72\\xc3\\xbc\\xc3\\x9f\\x65\\n'; pwd\r".utf8))
        try await waitUntil { String(decoding: received, as: UTF8.self).contains("Grüße") }
        try await waitUntil { String(decoding: received, as: UTF8.self).contains("/tmp") }
        let start = received.count
        session.send(Array("cat <<'EOF'\nfirst line\nsecond line\nEOF\r".utf8))
        try await waitUntil {
            String(decoding: received.dropFirst(start), as: UTF8.self).components(separatedBy: "second line").count >= 3
        }
        session.stage("```bash\ncat <<'EOF'\nGrüße vom Editor 🥧\nEOF\n```")
        let editorStart = received.count
        session.sendDraft()
        try await waitUntil { !session.sending && session.history.count == 1 }
        try await waitUntil {
            String(decoding: received.dropFirst(editorStart), as: UTF8.self)
                .components(separatedBy: "Grüße vom Editor 🥧").count >= 3
        }
        XCTAssertFalse(session.history[0].contains("```"))
        session.resize(cols: 91, rows: 33)
        session.send(Array("stty size\r".utf8))
        try await waitUntil { String(decoding: received, as: UTF8.self).contains("33 91") }
        session.disconnect()
        XCTAssertEqual(session.status, .disconnected)
        // A second connection reuses the pinned key without prompting.
        session.connect(device, route: .local)
        try await waitUntil { session.status == .connected }
        XCTAssertNil(session.trust)
        session.disconnect()
        // Exercise real SSH public-key signing with the deterministic fixture identity.
        device.authentication = .phoneKey
        session.connect(device, route: .local)
        try await waitUntil { session.status == .connected || session.error != nil }
        XCTAssertNil(session.error)
        guard session.status == .connected else { throw NSError(domain: session.error ?? "SSHKeyAuth", code: 1) }
        try await waitUntil { session.authenticationBanner.contains("SSH fixture authentication banner") }
        session.disconnect()
        // Tailscale SSH authenticates the VPN identity using the SSH 'none' method.
        device.username = "tailfixture"
        session.connect(device, route: .local)
        try await waitUntil { session.status == .connected }
        session.disconnect()
        // A key mismatch must stop before opening a shell.
        keys[endpoint] = "ssh-ed25519 wrong-key"
        defaults.set(keys, forKey: "trustedHostKeys")
        session.connect(device, route: .local)
        try await waitUntil { session.trust != nil && session.status == .disconnected }
        XCTAssertEqual(session.trust?.previousKey, "ssh-ed25519 wrong-key")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "SSH fixture did not reach expected state", file: file, line: line)
        if !condition() { throw NSError(domain: "SSHTestTimeout", code: 1) }
    }
}
