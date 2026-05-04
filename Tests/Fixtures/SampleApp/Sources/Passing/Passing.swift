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

struct UiThemeKey: EnvironmentKey {
    static let defaultValue: String = "system"
}

extension EnvironmentValues {
    var analytics: AnalyticsClient {
        get { self[AnalyticsKey.self] }
        set { self[AnalyticsKey.self] = newValue }
    }

    // swiftui-environment-audit: optional
    var uiTheme: String {
        get { self[UiThemeKey.self] }
        set { self[UiThemeKey.self] = newValue }
    }
}

struct PassingApp: App {
    @State private var state = MyState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .environment(\.analytics, AnalyticsClient { _ in })
        }
        Settings {
            SettingsRoot()
                .environment(state)
                .environment(\.analytics, AnalyticsClient { _ in })
            // \.uiTheme intentionally not provided — its declaration
            // carries the `optional` marker, so the audit ignores it.
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
    @Environment(\.uiTheme) private var theme

    var body: some View {
        Button("Tap") {
            analytics.send("tapped: \(theme)")
        }
        .overlay(Text("counter: \(state.counter)"))
    }
}
