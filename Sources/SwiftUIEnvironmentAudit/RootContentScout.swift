import Foundation
import SwiftSyntax

/// Walks a root content closure (a Scene body or a `#Preview` body) and
/// pulls out:
///   - root-level view constructors,
///   - every `.environment(arg)` call's argument expression with the
///     source location of arg's rightmost identifier,
///   - every `if let X = expr` / `guard let X = expr` / `let X = expr`
///     binding with arg resolved to a type via the index, so later
///     `.environment(X.foo)` resolution can use the local binding's
///     type.
final class RootContentScout: SyntaxVisitor {
    let knownViews: Set<String>
    let file: String
    let converter: SourceLocationConverter
    let resolver: IndexResolver
    var rootViews: Set<String> = []
    var providedExpressions: [ResolvableExpression] = []
    var providedKeypaths: Set<String> = []
    var localBindings: [String: String] = [:]

    init(
        knownViews: Set<String>,
        file: String,
        converter: SourceLocationConverter,
        resolver: IndexResolver
    ) {
        self.knownViews = knownViews
        self.file = file
        self.converter = converter
        self.resolver = resolver
        super.init(viewMode: .sourceAccurate)
    }

    /// Pick the body closure off a `Scene { ... }` call or a
    /// `#Preview { ... }` macro expansion. The trailing closure wins
    /// when present (the common shape for both); otherwise the last
    /// closure-typed argument is taken, which covers
    /// `#Preview("…", body: { … })` and similar labeled-only forms.
    static func bodyClosure(
        trailingClosure: ClosureExprSyntax?,
        arguments: LabeledExprListSyntax
    ) -> ClosureExprSyntax? {
        if let trailingClosure {
            return trailingClosure
        }
        return arguments
            .compactMap { $0.expression.as(ClosureExprSyntax.self) }
            .last
    }

    /// Finalize what the walk gathered into a `RootInfo`. Resolves each
    /// `.environment(arg)` argument against the index (with local
    /// bindings as a fallback) so the analyzer can compare provided
    /// types directly against the requirements declared by reachable
    /// views.
    func collect(
        kind: String,
        line: Int,
        origin: RootOrigin
    ) -> RootInfo {
        let providedTypes = providedExpressions.compactMap {
            resolver.resolve(expression: $0, bindings: localBindings)
        }
        var provided: Set<EnvKind> = []
        for typeName in providedTypes {
            provided.insert(.type(typeName))
        }
        for keypath in providedKeypaths {
            provided.insert(.keypath(keypath))
        }
        return RootInfo(
            kind: kind,
            sourceFile: file,
            line: line,
            rootViews: Array(rootViews),
            providedExpressions: providedExpressions,
            providedKeypaths: providedKeypaths,
            provided: provided,
            origin: origin,
            localBindings: localBindings
        )
    }

    override func visit(
        _ node: FunctionCallExprSyntax
    ) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression
            .as(DeclReferenceExprSyntax.self),
            knownViews.contains(callee.baseName.text)
        {
            rootViews.insert(callee.baseName.text)
        }
        if let member = node.calledExpression
            .as(MemberAccessExprSyntax.self),
            member.declName.baseName.text == "environment",
            let firstArg = node.arguments.first
        {
            if let keypath = firstArg.expression.as(KeyPathExprSyntax.self) {
                if let name = keypathName(keypath) {
                    providedKeypaths.insert(name)
                }
            }
            else {
                providedExpressions.append(
                    expression(from: firstArg.expression)
                )
            }
        }
        return .visitChildren
    }

    override func visit(
        _ node: OptionalBindingConditionSyntax
    ) -> SyntaxVisitorContinueKind {
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self),
            let initializer = node.initializer
        {
            recordBinding(
                name: pattern.identifier.text,
                rhs: initializer.value
            )
        }
        return .visitChildren
    }

    override func visit(
        _ node: PatternBindingSyntax
    ) -> SyntaxVisitorContinueKind {
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self),
            let initializer = node.initializer
        {
            recordBinding(
                name: pattern.identifier.text,
                rhs: initializer.value
            )
        }
        return .visitChildren
    }

    private func recordBinding(name: String, rhs: ExprSyntax) {
        let expr = expression(from: rhs)
        if let type = resolver.resolve(
            expression: expr,
            bindings: localBindings
        ) {
            localBindings[name] = type
        }
    }

    private func expression(from expr: ExprSyntax) -> ResolvableExpression {
        ResolvableExpression(
            text: expr.trimmedDescription,
            identifierLocation: rightmostIdentifierLocation(of: expr),
            constructorType: constructorType(of: expr)
        )
    }

    /// `MyState()` → `"MyState"`. Returns nil for any other shape (a
    /// property reference, a member-access chain, a non-constructor
    /// call). Uppercase-leading callee is the Swift convention for
    /// type constructors and matches the audit's view-discovery
    /// heuristic in `Catalogue.ConstructorCallScout`.
    private func constructorType(of expr: ExprSyntax) -> String? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
            let callee = call.calledExpression
                .as(DeclReferenceExprSyntax.self),
            callee.baseName.text.first?.isUppercase == true
        else {
            return nil
        }
        return callee.baseName.text
    }

    /// The position of the trailing identifier in a property-access
    /// chain (`uiState` in `appDelegate.uiState`, `libraryStore` in
    /// `appDelegate.appService?.libraryStore`, `appService` in a bare
    /// `appService`). Returns nil for forms whose result has no
    /// pinpointed identifier — call expressions terminate in parens,
    /// subscripts in brackets, etc.
    private func rightmostIdentifierLocation(
        of expr: ExprSyntax
    ) -> SourceLocation? {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return location(of: member.declName.baseName)
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return location(of: ref.baseName)
        }
        if let optional = expr.as(OptionalChainingExprSyntax.self) {
            return rightmostIdentifierLocation(
                of: ExprSyntax(optional.expression)
            )
        }
        if let force = expr.as(ForceUnwrapExprSyntax.self) {
            return rightmostIdentifierLocation(
                of: ExprSyntax(force.expression)
            )
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return rightmostIdentifierLocation(
                of: ExprSyntax(call.calledExpression)
            )
        }
        return nil
    }

    private func location(of token: TokenSyntax) -> SourceLocation {
        let loc = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        return SourceLocation(
            file: file,
            line: loc.line,
            utf8Column: loc.column
        )
    }
}
