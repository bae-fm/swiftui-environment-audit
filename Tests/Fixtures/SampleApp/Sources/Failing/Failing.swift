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

// BUG 3: preview renders `Inner` without injecting `MyState` or
// `\.analytics`. SwiftUI traps at render time the same way the missing
// Settings injection does — and the App-scoped audit alone wouldn't
// notice, because the preview is a separate root.
#Preview("Failing Inner") {
    Inner()
}

// MARK: - #1 custom env-bundle modifier that omits a required store

@Observable final class StoreA { var a = 0 }
@Observable final class StoreB { var b = 0 }

/// BUG 4: this bundle injects StoreA but forgets StoreB, so applying it
/// to a view that requires both leaves StoreB missing. Proves the modifier
/// expansion doesn't blanket-satisfy every requirement.
extension View {
    func partialPreviewEnvironment() -> some View {
        self.environment(StoreA())
    }
}

struct ImportPanel: View {
    @Environment(StoreA.self) private var a
    @Environment(StoreB.self) private var b

    var body: some View {
        Text("\(a.a) \(b.b)")
    }
}

#Preview("Partial bundle") {
    ImportPanel()
        .partialPreviewEnvironment()
}

// MARK: - #4 generic-wrapped inner whose env is NOT provided

struct Box<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

@Observable final class BoxedStore { var v = 0 }

struct BoxedInner: View {
    @Environment(BoxedStore.self) private var store
    var body: some View { Text("\(store.v)") }
}

// BUG 5: `BoxedInner` is wrapped in a generic `Box<…>` and its
// `BoxedStore` requirement is never injected. The audit must see through
// the generic wrapper to the inner requirement (otherwise it would miss
// this) and report it.
#Preview("Generic wrapper missing env") {
    Box {
        BoxedInner()
    }
}

// BUG 6: spelled `Box<SpecInner>(content:)` — the inner is reachable only
// through the generic argument (SpecInner() is constructed inside
// makeSpecInner, not the preview body), and its SpecStore is not injected.
// Proves the generic-argument extraction surfaces the requirement; a plain
// nested-call fallback wouldn't see SpecInner here.
@Observable final class SpecStore { var v = 0 }

struct SpecInner: View {
    @Environment(SpecStore.self) private var store
    var body: some View { Text("\(store.v)") }
}

func makeSpecInner() -> SpecInner {
    SpecInner()
}

#Preview("Spelled generic missing env") {
    Box<SpecInner>(content: makeSpecInner)
}
