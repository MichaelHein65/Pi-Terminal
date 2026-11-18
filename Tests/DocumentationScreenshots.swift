import XCTest
import SwiftUI
@testable import SSHClient

/// Capture native app screens using synthetic profiles and the loopback-only SSH fixture.
final class DocumentationScreenshots: XCTestCase {
    @MainActor
    func testCaptureDocumentationScreenshots() async throws {
        guard ProcessInfo.processInfo.environment["PI_TERMINAL_DOCS"] == "1" else {
            throw XCTSkip("Use the Documentation scheme to regenerate the documentation images.")
        }
        let folder = URL.documentsDirectory.appending(path: "documentation-screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let profiles = [
            Device(name: "Pi Zero", localHost: "pizero.local", tailscaleHost: "pizero.example.ts.net"),
            Device(name: "Pi 5", localHost: "pi5.local", tailscaleHost: "pi5.example.ts.net"),
            Device(name: "Pi 4", localHost: "pi4.local", tailscaleHost: "pi4.example.ts.net")
        ]
        let storage = folder.appending(path: "demo-devices.json")
        try JSONEncoder().encode(profiles).write(to: storage)
        let store = DeviceStore(storageURL: storage)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .systemBackground
        defer { window.isHidden = true }
        let home = UIHostingController(rootView: ContentView().environmentObject(store).tint(.teal))
        window.rootViewController = home
        window.makeKeyAndVisible()
        home.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        try capture(window, to: folder.appending(path: "devices.png"))

        let device = Device(name: "SSH Demo", localHost: "127.0.0.1", username: "fixture", port: 22222, authentication: .password)
        try Keychain.save("simulator-only", account: device.id.uuidString)
        let oldKeys = UserDefaults.standard.dictionary(forKey: "trustedHostKeys")
        var keys = oldKeys as? [String: String] ?? [:]
        keys.removeValue(forKey: "[127.0.0.1]:22222")
        UserDefaults.standard.set(keys, forKey: "trustedHostKeys")
        let session = SSHSession()
        defer {
            session.disconnect()
            try? Keychain.delete(account: device.id.uuidString)
            UserDefaults.standard.set(oldKeys, forKey: "trustedHostKeys")
        }
        session.connect(device, route: .local)
        try await until { session.trust != nil && session.status == .disconnected }
        session.acceptHost()
        try await until { session.status == .connected }
        let terminal = UIHostingController(rootView: NavigationStack { SessionView(device: device, session: session) }.tint(.teal))
        window.rootViewController = terminal
        terminal.view.layoutIfNeeded()
        try await until { session.draftSender != nil }
        session.draft = "# Befehle aus deiner LLM\nhostname; uptime"
        session.send(Array("clear\rcd /tmp\rprintf 'Hallo vom SSH-Terminal!\\n'; pwd\r".utf8))
        try await Task.sleep(for: .milliseconds(700))
        try capture(window, to: folder.appending(path: "terminal.png"))
    }

    @MainActor
    private func capture(_ window: UIWindow, to url: URL) throws {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let bytes = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(bytes).count, 32, "Documentation screenshot must contain rendered content")
        try XCTUnwrap(image.pngData()).write(to: url)
    }
    @MainActor
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { throw NSError(domain: "DocumentationScreenshotTimeout", code: 1) }
    }
}
