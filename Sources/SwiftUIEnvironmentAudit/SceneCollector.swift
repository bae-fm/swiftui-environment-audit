import Foundation
import SwiftParser
import SwiftSyntax

/// Walks every `: App` declaration found by `Catalogue` and extracts
/// each `Scene { ... }` call inside its `body`. For each scene we
/// record the root view type(s) it constructs, the `.environment(...)`
/// modifiers chained on anything inside its content closure (with the
/// source location of each argument's rightmost identifier), and the
/// local `let`/`if let` bindings introduced inside the closure (with
/// their resolved types). Results land in `roots` as `RootInfo` values
/// with a `.scene(...)` origin, alongside any previews picked up by
/// `PreviewCollector`.
final class SceneCollector {
    private let catalogue: Catalogue
    private let resolver: IndexResolver
    private(set) var roots: [RootInfo] = []

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
            sink: { [weak self] root in
                self?.roots.append(root)
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
    let sink: (RootInfo) -> Void
    private var typeStack: [String] = []

    init(
        file: String,
        converter: SourceLocationConverter,
        catalogue: Catalogue,
        resolver: IndexResolver,
        sink: @escaping (RootInfo) -> Void
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
            enclosingApp: enclosing
        ) {
            sink(info)
        }
        return .visitChildren
    }

    private func makeScene(
        from call: FunctionCallExprSyntax,
        kind: String,
        enclosingApp: String
    ) -> RootInfo? {
        guard let closure = RootContentScout.bodyClosure(
            trailingClosure: call.trailingClosure,
            arguments: call.arguments
        ) else {
            return nil
        }
        let line = converter.location(for: call.position).line
        let scout = RootContentScout(
            knownViews: Set(catalogue.views.keys),
            file: file,
            converter: converter,
            resolver: resolver
        )
        scout.walk(closure.statements)
        return scout.collect(
            kind: kind,
            line: line,
            origin: .scene(enclosingApp: enclosingApp)
        )
    }
}
