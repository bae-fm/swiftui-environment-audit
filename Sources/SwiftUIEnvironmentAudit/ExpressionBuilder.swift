import SwiftSyntax

/// Shared expression-capture logic used by both the root-content walk
/// (`RootContentScout`, for `.environment(arg)` modifiers chained inside a
/// Scene or `#Preview` body) and the modifier-body walk (`Catalogue`, for
/// `.environment(arg)` calls inside a custom `extension View` modifier).
///
/// Both need to turn an argument expression into a `ResolvableExpression`
/// the `IndexResolver` can later resolve to a type. The source location is
/// computed against the file the expression actually lives in, so a
/// modifier's captured expressions point into the modifier's source file —
/// `IndexResolver` resolves by absolute file:line:column, so the captured
/// location is enough to resolve a modifier's provision even though the
/// modifier is applied in a different file.
enum ExpressionBuilder {
    /// Build a `ResolvableExpression` for `expr` as it appears in `file`.
    static func expression(
        from expr: ExprSyntax,
        file: String,
        converter: SourceLocationConverter
    ) -> ResolvableExpression {
        ResolvableExpression(
            text: expr.trimmedDescription,
            identifierLocation: rightmostIdentifierLocation(
                of: expr,
                file: file,
                converter: converter
            ),
            constructorType: constructorType(of: expr)
        )
    }

    /// `MyState()` → `"MyState"`. Returns nil for any other shape (a
    /// property reference, a member-access chain, a non-constructor
    /// call). Uppercase-leading callee is the Swift convention for type
    /// constructors and matches the audit's view-discovery heuristic in
    /// `Catalogue.ConstructorCallScout`.
    static func constructorType(of expr: ExprSyntax) -> String? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
            let callee = call.calledExpression
                .as(DeclReferenceExprSyntax.self),
            callee.baseName.text.first?.isUppercase == true
        else {
            return nil
        }
        return callee.baseName.text
    }

    /// The position of the trailing identifier in a property-access chain
    /// (`uiState` in `appDelegate.uiState`, `libraryStore` in
    /// `appDelegate.appService?.libraryStore`, `appService` in a bare
    /// `appService`). Returns nil for forms whose result has no pinpointed
    /// identifier — call expressions terminate in parens, subscripts in
    /// brackets, etc.
    static func rightmostIdentifierLocation(
        of expr: ExprSyntax,
        file: String,
        converter: SourceLocationConverter
    ) -> SourceLocation? {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return location(of: member.declName.baseName, file: file, converter: converter)
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return location(of: ref.baseName, file: file, converter: converter)
        }
        if let optional = expr.as(OptionalChainingExprSyntax.self) {
            return rightmostIdentifierLocation(
                of: ExprSyntax(optional.expression),
                file: file,
                converter: converter
            )
        }
        if let force = expr.as(ForceUnwrapExprSyntax.self) {
            return rightmostIdentifierLocation(
                of: ExprSyntax(force.expression),
                file: file,
                converter: converter
            )
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return rightmostIdentifierLocation(
                of: ExprSyntax(call.calledExpression),
                file: file,
                converter: converter
            )
        }
        return nil
    }

    private static func location(
        of token: TokenSyntax,
        file: String,
        converter: SourceLocationConverter
    ) -> SourceLocation {
        let loc = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        return SourceLocation(
            file: file,
            line: loc.line,
            utf8Column: loc.column
        )
    }
}
