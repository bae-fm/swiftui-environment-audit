import SwiftUI

@Observable
final class MyState {
    var counter = 0
}

struct FailingApp: App {
    @State private var state = MyState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
        }
        Settings {
            // BUG: forgot `.environment(state)` — `Inner` will crash at
            // render time because `MyState` is missing from the scene's
            // environment.
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

    var body: some View {
        Text("counter: \(state.counter)")
    }
}
