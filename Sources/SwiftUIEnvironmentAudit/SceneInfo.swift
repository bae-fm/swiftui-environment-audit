/// One `Scene { ... }` call inside an `App.body`.
struct SceneInfo {
    let kind: String
    let sourceFile: String
    let line: Int
    /// View types instantiated as roots inside the scene's content closure.
    /// Multiple entries when control flow (`if let`/`switch`) produces
    /// different roots in different branches.
    let rootViews: [String]
    /// `.environment(arg)` modifiers with their rightmost identifier
    /// locations, so the resolver can ask the index what each arg's type is.
    let providedExpressions: [ResolvableExpression]
    /// Keypath names from `.environment(\.someKey, value)` modifiers, e.g.
    /// `"someKey"` for `\.someKey`. Captured separately from
    /// `providedExpressions` because the keypath form doesn't need type
    /// resolution — the keypath name itself is the identifier.
    let providedKeypaths: Set<String>
    /// Union of everything this scene provides:
    ///   - `.type(T)` for each `providedExpressions` entry the resolver
    ///     successfully resolved to a type, plus
    ///   - `.keypath(K)` for each `providedKeypaths` entry.
    let provided: Set<EnvKind>
    /// The enclosing `App`-conforming type. Always populated —
    /// `SceneCollector` only emits scenes that live inside an `: App`
    /// declaration.
    let enclosingType: String
    /// Local-binding name → resolved type, collected from `if let X = expr`,
    /// `guard let X = expr`, and `let X = expr` inside the scene's closure.
    /// Captured separately because the Swift indexer does not record
    /// references to local lets, so the resolver can't find them via the
    /// index and falls back to this map.
    let localBindings: [String: String]
}
