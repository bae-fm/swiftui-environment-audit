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
    /// Set of types the resolver successfully extracted from
    /// `providedExpressions`.
    let providedTypes: Set<String>
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
