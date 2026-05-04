import SwiftUI

@Observable
final class MyState {
    var counter = 0
}

struct AnalyticsClient {
    let send: (String) -> Void
}

struct AnalyticsKey: EnvironmentKey {
    static let defaultValue: AnalyticsClient = AnalyticsClient { _ in }
}

extension EnvironmentValues {
    var analytics: AnalyticsClient {
        get { self[AnalyticsKey.self] }
        set { self[AnalyticsKey.self] = newValue }
    }
}

struct FailingApp: App {
    @State private var state = MyState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .environment(\.analytics, AnalyticsClient { _ in })
        }
        Settings {
            // BUG 1: missing `.environment(state)` — `Inner` requires
            // `MyState`.
            // BUG 2: missing `.environment(\.analytics, …)` — `Inner`
            // reads `\.analytics`, whose default is a no-op placeholder.
            SettingsRoot()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Main")
    }
}

struct SettingsRoot: View {
    var body: some View {
        Inner()
    }
}

struct Inner: View {
    @Environment(MyState.self) private var state
    @Environment(\.analytics) private var analytics

    var body: some View {
        Button("Tap") {
            analytics.send("tapped")
        }
        .overlay(Text("counter: \(state.counter)"))
    }
}
