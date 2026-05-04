import Foundation
import SwiftParser
import SwiftSyntax

/// Walks every `: App` declaration found by `Catalogue` and extracts each
/// `Scene { ... }` call inside its `body`. For each scene we record the
/// root view type(s) it constructs, the `.environment(...)` modifiers
/// chained on anything inside its content closure (with the source
/// location of each argument's rightmost identifier), and the local
/// `let`/`if let` bindings introduced inside the closure (with their
/// resolved types).
final class SceneCollector {
    private let catalogue: Catalogue
    private let resolver: IndexResolver
    private(set) var scenes: [SceneInfo] = []

    init(catalogue: Catalogue, resolver: IndexResolver) {
        self.catalogue = catalogue
        self.resolver = resolver
    }

    static let knownSceneKinds: Set<String> = [
        "Window",
        "WindowGroup",
        "Settings",
        "MenuBarExtra",
        "DocumentGroup",
        "ImmersiveSpace",
    ]

    func ingest(file: URL) throws {
        let source = try String(contentsOf: file, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(
            fileName: file.path,
            tree: tree
        )
        let visitor = AppBodyVisitor(
            file: file.path,
            converter: converter,
            catalogue: catalogue,
            resolver: resolver,
            sink: { [weak self] scene in
                self?.scenes.append(scene)
            }
        )
        visitor.walk(tree)
    }
}

private final class AppBodyVisitor: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    let catalogue: Catalogue
    let resolver: IndexResolver
    let sink: (SceneInfo) -> Void
    private var typeStack: [String] = []

    init(
        file: String,
        converter: SourceLocationConverter,
        catalogue: Catalogue,
        resolver: IndexResolver,
        sink: @escaping (SceneInfo) -> Void
    ) {
        self.file = file
        self.converter = converter
        self.catalogue = catalogue
        self.resolver = resolver
        self.sink = sink
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        typeStack.removeLast()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        typeStack.removeLast()
    }

    override func visit(
        _ node: FunctionCallExprSyntax
    ) -> SyntaxVisitorContinueKind {
        guard let enclosing = typeStack.last,
            catalogue.apps.contains(enclosing)
        else {
            return .visitChildren
        }
        guard let callee = node.calledExpression
            .as(DeclReferenceExprSyntax.self),
            SceneCollector.knownSceneKinds.contains(callee.baseName.text)
        else {
            return .visitChildren
        }
        if let info = makeScene(
            from: node,
            kind: callee.baseName.text,
            enclosingType: enclosing
        ) {
            sink(info)
        }
        return .visitChildren
    }

    private func makeScene(
        from call: FunctionCallExprSyntax,
        kind: String,
        enclosingType: String
    ) -> SceneInfo? {
        let closure: ClosureExprSyntax?
        if let trailing = call.trailingClosure {
            closure = trailing
        }
        else {
            closure = call.arguments
                .compactMap { $0.expression.as(ClosureExprSyntax.self) }
                .last
        }
        guard let closure else {
            return nil
        }
        let line = converter.location(for: call.position).line
        let scout = SceneContentScout(
            knownViews: Set(catalogue.views.keys),
            file: file,
            converter: converter,
            resolver: resolver
        )
        scout.walk(closure.statements)
        let providedTypes = scout.providedExpressions.compactMap {
            resolver.resolve(expression: $0, bindings: scout.localBindings)
        }
        return SceneInfo(
            kind: kind,
            sourceFile: file,
            line: line,
            rootViews: Array(scout.rootViews),
            providedExpressions: scout.providedExpressions,
            providedTypes: Set(providedTypes),
            enclosingType: enclosingType,
            localBindings: scout.localBindings
        )
    }
}

/// Walks a Scene's content closure and pulls out:
///   - root-level view constructors,
///   - every `.environment(arg)` call's argument expression with the
///     source location of arg's rightmost identifier,
///   - every `if let X = expr` / `guard let X = expr` / `let X = expr`
///     binding with arg resolved to a type via the index, so later
///     `.environment(X.foo)` resolution can use the local binding's type.
private final class SceneContentScout: SyntaxVisitor {
    let knownViews: Set<String>
    let file: String
    let converter: SourceLocationConverter
    let resolver: IndexResolver
    var rootViews: Set<String> = []
    var providedExpressions: [ResolvableExpression] = []
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
            // Skip the keypath form: `.environment(\.key, value)`.
            if firstArg.expression.is(KeyPathExprSyntax.self) == false {
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
            identifierLocation: rightmostIdentifierLocation(of: expr)
        )
    }

    /// The position of the trailing identifier in a property-access chain
    /// (`uiState` in `appDelegate.uiState`, `libraryStore` in
    /// `appDelegate.appService?.libraryStore`, `appService` in a bare
    /// `appService`). Returns nil for forms whose result has no pinpointed
    /// identifier — call expressions terminate in parens, subscripts in
    /// brackets, etc.
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
