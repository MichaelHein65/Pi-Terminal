import SwiftUI
import SwiftTerm

final class StagedTerminalView: TerminalView {
    var stagePaste: ((String) -> Void)?
    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { stagePaste?(text) }
    }
}

struct TerminalBridge: UIViewRepresentable {
    @ObservedObject var session: SSHSession
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeUIView(context: Context) -> StagedTerminalView {
        let view = StagedTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = UIColor(red: 0.035, green: 0.055, blue: 0.085, alpha: 1)
        view.nativeForegroundColor = UIColor(red: 0.82, green: 0.91, blue: 0.90, alpha: 1)
        view.terminalDelegate = context.coordinator
        view.stagePaste = { [weak session] in session?.stage($0) }
        session.receive = { [weak view] bytes in view?.feed(byteArray: bytes[...]) }
        session.draftSender = { [weak view, weak session] text, completion in
            guard let view, let session else { return }
            var payload = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if view.getTerminal().bracketedPasteMode {
                payload = "\u{1b}[200~" + payload + "\u{1b}[201~"
            }
            payload += "\r"
            session.send(Array(payload.utf8), completion: completion)
        }
        view.feed(text: "Pi Terminal\r\nVerbinde ein Gerät, um die Shell zu öffnen.\r\n")
        return view
    }
    func updateUIView(_ uiView: StagedTerminalView, context: Context) {
        uiView.stagePaste = { [weak session] in session?.stage($0) }
    }
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let session: SSHSession
        init(_ session: SSHSession) { self.session = session }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session.resize(cols: newCols, rows: newRows) }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { session.send(Array(data)) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        // Remote OSC 52 requests cannot read or overwrite the local clipboard.
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
    }
}
