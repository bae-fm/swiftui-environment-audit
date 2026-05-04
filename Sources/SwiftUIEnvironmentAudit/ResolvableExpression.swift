/// One `.environment(arg)` modifier captured from a Scene's content closure
/// (or one `if let X = arg` RHS captured from the same closure). The `text`
/// is the raw source for reporting; `identifierLocation` is the position of
/// the rightmost identifier in the expression — what we hand to the index
/// to ask "what's the type at this point?".
///
/// `identifierLocation` is nil for expressions whose result has no
/// identifier we can pin (literals, complex computed expressions). Those
/// fall through to `<unresolved>` rather than producing a wrong answer.
struct ResolvableExpression {
    let text: String
    let identifierLocation: SourceLocation?
}
