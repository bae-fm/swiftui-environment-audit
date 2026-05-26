/// One root view tree the audit walks: either a `Scene { ... }` inside
/// an `App.body` or a freestanding `#Preview { ... }` macro expansion.
/// Both shapes share the same set of questions — which views does this
/// tree instantiate, and which environment values does it provide — so
/// the audit treats them uniformly. `origin` is the discriminator.
struct RootInfo {
    /// The container that introduced the tree. For scenes, the SwiftUI
    /// Scene type name (`"WindowGroup"`, `"Settings"`, …); for previews,
    /// the literal string `"Preview"`.
    let kind: String
    let sourceFile: String
    let line: Int
    /// View types instantiated as roots inside the content closure.
    /// Multiple entries when control flow (`if let`/`switch`) produces
    /// different roots in different branches.
    let rootViews: [String]
    /// `.environment(arg)` modifiers with their rightmost identifier
    /// locations, so the resolver can ask the index what each arg's type
    /// is.
    let providedExpressions: [ResolvableExpression]
    /// Keypath names from `.environment(\.someKey, value)` modifiers,
    /// e.g. `"someKey"` for `\.someKey`. Captured separately from
    /// `providedExpressions` because the keypath form doesn't need type
    /// resolution — the keypath name itself is the identifier.
    let providedKeypaths: Set<String>
    /// Union of everything this root provides:
    ///   - `.type(T)` for each `providedExpressions` entry the resolver
    ///     successfully resolved to a type, plus
    ///   - `.keypath(K)` for each `providedKeypaths` entry.
    let provided: Set<EnvKind>
    let origin: RootOrigin
    /// Local-binding name → resolved type, collected from
    /// `if let X = expr`, `guard let X = expr`, and `let X = expr`
    /// inside the content closure. Captured separately because the
    /// Swift indexer does not record references to local lets, so the
    /// resolver can't find them via the index and falls back to this
    /// map.
    let localBindings: [String: String]
}
