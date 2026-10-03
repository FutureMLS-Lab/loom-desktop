import SwiftUI

@main
struct LoomApp: App {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var sessions = SessionCache()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything reads the server list: an install that replaced the
        // React Native app inherits its container, servers and tokens included.
        LegacyServerImport.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(workspace)
                .environmentObject(sessions)
                .tint(LoomColors.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                workspace.start()
                workspace.refreshNow()
            case .background:
                workspace.stop()
            default:
                break
            }
        }
    }
}
