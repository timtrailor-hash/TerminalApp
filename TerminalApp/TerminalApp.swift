import SwiftUI
import TimSharedKit

@main
struct TerminalApp: App {
    @StateObject private var server = ServerConnection()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TerminalView()
            }
            .environmentObject(server)
            .preferredColorScheme(.dark)
        }
    }
}
