import SwiftUI

@main
struct LoomWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @StateObject private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        DebugLaunch.apply()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(WatchRouter.shared)
                .environmentObject(PhoneSync.shared)
                .tint(LoomColors.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.setForeground(true)
                store.start()
                store.refreshNow()
            case .inactive:
                // Wrist down, still frontmost: keep watching at a walk, and
                // let news arrive as notifications.
                store.setForeground(false)
            case .background:
                store.setForeground(false)
                store.stop()
            @unknown default:
                break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: WatchStore
    @EnvironmentObject private var router: WatchRouter

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if store.hasServer {
                    HomeView()
                } else {
                    OnboardingView()
                }
            }
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .task(let ref):
                    TaskView(ref: ref, paneTarget: store.meta(for: ref)?.1.tmux_interview_target ?? "")
                case .allTasks:
                    AllTasksView()
                case .servers:
                    ServersView()
                }
            }
        }
        .onChange(of: store.activeServerID) { _, _ in router.serverDidSwitch() }
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var phone: PhoneSync

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(LoomColors.accent)
                Text("Set up on iPhone")
                    .font(.headline)
                Text("Add a server in Loom on your iPhone. It shows up here on its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    phone.requestServers()
                } label: {
                    if phone.requesting {
                        ProgressView()
                    } else {
                        Label("Check Again", systemImage: "iphone.and.arrow.forward")
                    }
                }
                .disabled(!phone.phoneReachable || phone.requesting)
                if !phone.phoneReachable {
                    Text("Your iPhone isn't reachable right now.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Loom")
        .containerBackground(LoomColors.accent.gradient, for: .navigation)
    }
}

#if DEBUG
/// Simulator runs, which have no iPhone to sync from:
/// `-LoomWatchServer http://127.0.0.1:8787` (and `-LoomWatchToken …` when the
/// server wants one) stands in for the list the phone would send.
enum DebugLaunch {
    static func apply() {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "LoomWatchServer"), !url.isEmpty else { return }
        let server = LoomServer(
            id: "debug-launch",
            name: defaults.string(forKey: "LoomWatchServerName") ?? "Mock Loom",
            baseURL: url,
            token: defaults.string(forKey: "LoomWatchToken") ?? ""
        )
        LoomSettings.servers = [server]
        LoomSettings.activeServerID = server.id
    }
}
#endif
