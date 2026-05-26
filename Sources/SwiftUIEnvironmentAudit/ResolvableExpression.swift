/// One `.environment(arg)` modifier captured from a root content closure
/// (or one `if let X = arg` RHS captured from the same closure). The
/// `text` is the raw source for reporting; `identifierLocation` is the
/// position of the rightmost identifier in the expression — what we
/// hand to the index to ask "what's the type at this point?".
///
/// `identifierLocation` is nil for expressions whose result has no
/// identifier we can pin (literals, complex computed expressions). Those
/// fall through to `<unresolved>` rather than producing a wrong answer.
///
/// `constructorType` is set when the expression is a literal `T(...)`
/// constructor call. Previews routinely write `.environment(MyState())`
/// inline because they have no enclosing App to hold the value, and a
/// type symbol in the index isn't a property — `propertyType(forUSR:)`
/// would return nil. The AST already tells us the type at capture time,
/// so the resolver short-circuits on this field before consulting the
/// index.
struct ResolvableExpression {
    let text: String
    let identifierLocation: SourceLocation?
    let constructorType: String?
}
