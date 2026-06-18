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
    /// Resolved custom `extension View` modifiers (`func fooEnv() -> some
    /// View { self.environment(...) }`). When the walk sees a known
    /// modifier applied (`.fooEnv()`), it folds that modifier's captured
    /// provisions into this root's, so the env it injects counts.
    let viewModifiers: [String: ResolvedViewModifier]
    var rootViews: Set<String> = []
    var providedExpressions: [ResolvableExpression] = []
    var providedKeypaths: Set<String> = []
    var localBindings: [String: String] = [:]

    init(
        knownViews: Set<String>,
        file: String,
        converter: SourceLocationConverter,
        resolver: IndexResolver,
        viewModifiers: [String: ResolvedViewModifier] = [:]
    ) {
        self.knownViews = knownViews
        self.file = file
        self.converter = converter
        self.resolver = resolver
        self.viewModifiers = viewModifiers
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
        for name in viewNames(fromCallee: node.calledExpression)
        where knownViews.contains(name) {
            rootViews.insert(name)
        }
        if let member = node.calledExpression
            .as(MemberAccessExprSyntax.self)
        {
            let memberName = member.declName.baseName.text
            // `.environment(arg)` / `.environmentObject(arg)` — a literal
            // provision attached somewhere in this body.
            if memberName == "environment" || memberName == "environmentObject",
                let firstArg = node.arguments.first
            {
                if let keypath = firstArg.expression.as(KeyPathExprSyntax.self) {
                    if let name = keypathName(keypath) {
                        providedKeypaths.insert(name)
                    }
                }
                else {
                    providedExpressions.append(
                        ExpressionBuilder.expression(
                            from: firstArg.expression,
                            file: file,
                            converter: converter
                        )
                    )
                }
            }
            // `.fooPreviewEnv()` — a custom `extension View` modifier whose
            // body applies env. Fold in its captured provisions.
            else if let modifier = viewModifiers[memberName] {
                providedExpressions.append(contentsOf: modifier.exprs)
                providedKeypaths.formUnion(modifier.keypaths)
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
                annotation: node.typeAnnotation,
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
                annotation: node.typeAnnotation,
                rhs: initializer.value
            )
        }
        return .visitChildren
    }

    /// Record `let x = …` / `let x: T = …` so a later `.environment(x)`
    /// resolves. When the binding carries an explicit `typeAnnotation`,
    /// trust it directly and skip resolving the RHS — that handles forms
    /// the index/AST can't see through, e.g. an immediately-invoked
    /// closure `let store: ImportStore = { … }()`.
    private func recordBinding(
        name: String,
        annotation: TypeAnnotationSyntax?,
        rhs: ExprSyntax
    ) {
        if let annotation {
            localBindings[name] = IndexResolver.stripOptional(
                annotation.type.trimmedDescription
            )
            return
        }
        let expr = ExpressionBuilder.expression(
            from: rhs,
            file: file,
            converter: converter
        )
        if let type = resolver.resolve(
            expression: expr,
            bindings: localBindings
        ) {
            localBindings[name] = type
        }
    }

    /// The view type name(s) a call's callee names, for root detection.
    /// A plain `Inner(...)` yields `["Inner"]`. A generic-specialized
    /// `Box<Inner>(...)` callee is a `GenericSpecializationExprSyntax`, so
    /// it yields the base view (`Box`) plus every generic argument that is
    /// an uppercase identifier type (`Inner`) — the wrapped content is a
    /// root whose env requirements must be satisfied too.
    private func viewNames(fromCallee callee: ExprSyntax) -> [String] {
        genericViewNames(fromCallee: callee)
    }
}

/// `Box<Inner>(…)`'s callee is a `GenericSpecializationExprSyntax`; a plain
/// `Inner(…)`'s callee is a `DeclReferenceExprSyntax`. Both the
/// root-content walk and `Catalogue.ConstructorCallScout` need the same
/// extraction — base view name (uppercase-leading) plus each uppercase
/// generic-argument type — so it lives as a free function shared by both.
func genericViewNames(fromCallee callee: ExprSyntax) -> [String] {
    if let ref = callee.as(DeclReferenceExprSyntax.self) {
        let name = ref.baseName.text
        return name.first?.isUppercase == true ? [name] : []
    }
    guard let specialized = callee.as(GenericSpecializationExprSyntax.self)
    else {
        return []
    }
    var names: [String] = []
    if let base = specialized.expression.as(DeclReferenceExprSyntax.self),
        base.baseName.text.first?.isUppercase == true
    {
        names.append(base.baseName.text)
    }
    for argument in specialized.genericArgumentClause.arguments {
        guard let identifierType = argument.argument
            .as(IdentifierTypeSyntax.self)
        else {
            continue
        }
        let name = identifierType.name.text
        if name.first?.isUppercase == true {
            names.append(name)
        }
    }
    return names
}
