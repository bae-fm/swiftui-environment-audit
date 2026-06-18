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

// Preview parallels the Settings scene above: injects every required
// environment value, omits the `\.uiTheme` opt-out key. Audit should
// report no finding for this tree.
#Preview("Passing Inner") {
    Inner()
        .environment(MyState())
        .environment(\.analytics, AnalyticsClient { _ in })
}

// MARK: - #1 custom env-bundle view modifier

@Observable final class StoreA { var a = 0 }
@Observable final class StoreB { var b = 0 }

/// A custom `extension View` modifier that bundles env injections. The
/// audit must treat applying `.importPreviewEnvironment()` as providing
/// both StoreA and StoreB.
extension View {
    func importPreviewEnvironment() -> some View {
        self
            .environment(StoreA())
            .environment(StoreB())
    }

    /// Transitive case: this modifier provides nothing itself but wraps
    /// the bundle above. Applying it must still satisfy StoreA + StoreB.
    func wrappedPreviewEnvironment() -> some View {
        self.importPreviewEnvironment()
    }
}

struct ImportPanel: View {
    @Environment(StoreA.self) private var a
    @Environment(StoreB.self) private var b

    var body: some View {
        Text("\(a.a) \(b.b)")
    }
}

#Preview("Bundle modifier") {
    ImportPanel()
        .importPreviewEnvironment()
}

#Preview("Transitive bundle modifier") {
    ImportPanel()
        .wrappedPreviewEnvironment()
}

// MARK: - #2 local binding via type annotation (IIFE)

@Observable final class AnnotatedStore { var v = 0 }

struct AnnotatedView: View {
    @Environment(AnnotatedStore.self) private var store
    var body: some View { Text("\(store.v)") }
}

#Preview("Annotated local") {
    // The RHS is an immediately-invoked closure — neither the index nor
    // the AST constructor path can see through it. The `: AnnotatedStore`
    // annotation is what resolves the binding.
    let store: AnnotatedStore = {
        let s = AnnotatedStore()
        s.v = 1
        return s
    }()
    return AnnotatedView()
        .environment(store)
}

// MARK: - #3/#5 function return type

@Observable final class FactoryStore { var v = 0 }

func makeFactoryStore() -> FactoryStore {
    FactoryStore()
}

struct FactoryView: View {
    @Environment(FactoryStore.self) private var store
    var body: some View { Text("\(store.v)") }
}

#Preview("Factory function") {
    FactoryView()
        .environment(makeFactoryStore())
}

// MARK: - #7 @EnvironmentObject via .environmentObject(...)

final class LegacyStore: ObservableObject {
    @Published var v = 0
}

struct LegacyView: View {
    @EnvironmentObject private var legacy: LegacyStore
    var body: some View { Text("\(legacy.v)") }
}

#Preview("EnvironmentObject") {
    LegacyView()
        .environmentObject(LegacyStore())
}

// MARK: - #4 generic wrapper whose Content requires env

struct Box<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

@Observable final class BoxedStore { var v = 0 }

struct BoxedInner: View {
    @Environment(BoxedStore.self) private var store
    var body: some View { Text("\(store.v)") }
}

#Preview("Generic wrapper") {
    Box {
        BoxedInner()
    }
    .environment(BoxedStore())
}

// Spelled generic specialization `Box<SpecInner>(content:)` — its callee is
// a GenericSpecializationExprSyntax, so the generic-argument extraction is
// what discovers `SpecInner` as a root. `SpecInner()` is constructed only
// inside `makeSpecInner` (a separate decl), so within this preview body the
// view is reachable *only* through the generic argument — if the generic
// branch missed it, its SpecStore requirement would never be seen.
@Observable final class SpecStore { var v = 0 }

struct SpecInner: View {
    @Environment(SpecStore.self) private var store
    var body: some View { Text("\(store.v)") }
}

func makeSpecInner() -> SpecInner {
    SpecInner()
}

#Preview("Spelled generic specialization") {
    Box<SpecInner>(content: makeSpecInner)
        .environment(SpecStore())
}
