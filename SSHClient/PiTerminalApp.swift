import SwiftUI

@main
struct PiTerminalApp: App {
    @StateObject private var store = DeviceStore()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(store).tint(.teal)
                .task {
                    #if !targetEnvironment(simulator)
                    do { try PhoneIdentity.prepare(); try NetworkAddresses.export() }
                    catch { store.error = error.localizedDescription }
                    #endif
                } }
    }
}
