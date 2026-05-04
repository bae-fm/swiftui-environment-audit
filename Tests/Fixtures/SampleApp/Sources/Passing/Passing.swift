import SwiftUI

@Observable
final class MyState {
    var counter = 0
}

struct PassingApp: App {
    @State private var state = MyState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
        }
        Settings {
            SettingsRoot()
                .environment(state)
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
