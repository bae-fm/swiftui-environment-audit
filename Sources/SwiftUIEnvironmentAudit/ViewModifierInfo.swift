/// A custom `extension View` modifier method that applies environment
/// values to `self` — e.g.
///
/// ```swift
/// extension View {
///     func importPreviewEnvironment() -> some View {
///         self.environment(ImportStore())
///             .environment(\.analytics, AnalyticsClient.preview)
///     }
/// }
/// ```
///
/// The audit treats applying such a modifier (`.importPreviewEnvironment()`)
/// as providing everything the modifier's body injects. `RawViewModifier`
/// is what `Catalogue` captures per file from the AST; `ResolvedViewModifier`
/// is what it becomes after `linkModifiers()` expands each modifier's
/// provisions transitively over the other modifiers it calls.
struct RawViewModifier {
    /// `.environment(arg)` / `.environmentObject(arg)` arguments captured
    /// from the body, with source locations pointing into the modifier's
    /// own file so `IndexResolver` can resolve them.
    var exprs: [ResolvableExpression] = []
    /// `.environment(\.key, …)` keypath names from the body.
    var keypaths: Set<String> = []
    /// Names of other `extension View` modifier methods this body calls
    /// (member calls whose name isn't `environment`/`environmentObject`).
    /// `linkModifiers()` follows these so a modifier that wraps another
    /// inherits its provisions.
    var calledModifiers: Set<String> = []
}

/// A view modifier's provisions after transitive expansion. Holds only what
/// `RootContentScout` needs to fold into a root: the resolvable expressions
/// and the keypaths. The expressions carry their own source locations, so
/// the resolver handles them exactly like inline `.environment(...)` args.
struct ResolvedViewModifier {
    let exprs: [ResolvableExpression]
    let keypaths: Set<String>
}
