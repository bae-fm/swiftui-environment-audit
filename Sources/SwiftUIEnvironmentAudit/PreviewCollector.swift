import Foundation
import SwiftParser
import SwiftSyntax

/// Walks every freestanding `#Preview { ... }` macro expansion and
/// records it as a `RootInfo` with the same shape `SceneCollector`
/// produces for SwiftUI Scenes. Previews crash at render time the same
/// way Scene roots do when their view tree reads
/// `@Environment(SomeType.self)` for a type no ancestor
/// `.environment(...)` provides — the App-scoped walk alone misses
/// these because the preview is a separate root.
///
/// SwiftSyntax parses `#Preview { ... }` as a `MacroExpansionExprSyntax`
/// wrapped in a code-block statement at file scope (not the decl form
/// that other freestanding macros sometimes take); both expr and decl
/// shapes are handled so a future parser change doesn't quietly drop
/// coverage.
final class PreviewCollector {
    private let catalogue: Catalogue
    private let resolver: IndexResolver
    private(set) var roots: [RootInfo] = []

    init(catalogue: Catalogue, resolver: IndexResolver) {
        self.catalogue = catalogue
        self.resolver = resolver
    }

    func ingest(file: URL) throws {
        let source = try String(contentsOf: file, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(
            fileName: file.path,
            tree: tree
        )
        let visitor = PreviewMacroVisitor(
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

private final class PreviewMacroVisitor: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    let catalogue: Catalogue
    let resolver: IndexResolver
    let sink: (RootInfo) -> Void

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

    override func visit(
        _ node: MacroExpansionDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        handlePreview(
            macroName: node.macroName,
            arguments: node.arguments,
            trailingClosure: node.trailingClosure,
            position: node.position
        )
        return .visitChildren
    }

    override func visit(
        _ node: MacroExpansionExprSyntax
    ) -> SyntaxVisitorContinueKind {
        handlePreview(
            macroName: node.macroName,
            arguments: node.arguments,
            trailingClosure: node.trailingClosure,
            position: node.position
        )
        return .visitChildren
    }

    private func handlePreview(
        macroName: TokenSyntax,
        arguments: LabeledExprListSyntax,
        trailingClosure: ClosureExprSyntax?,
        position: AbsolutePosition
    ) {
        guard macroName.text == "Preview" else {
            return
        }
        guard let closure = RootContentScout.bodyClosure(
            trailingClosure: trailingClosure,
            arguments: arguments
        ) else {
            return
        }
        let line = converter.location(for: position).line
        let scout = RootContentScout(
            knownViews: Set(catalogue.views.keys),
            file: file,
            converter: converter,
            resolver: resolver,
            viewModifiers: catalogue.viewModifiers
        )
        scout.walk(closure.statements)
        let info = scout.collect(
            kind: "Preview",
            line: line,
            origin: .preview(label: previewLabel(from: arguments))
        )
        sink(info)
    }

    /// The first positional argument of a `#Preview(...)` call is the
    /// optional display label as a string literal. Returns nil for
    /// the no-arg form (`#Preview { ... }`) and for the labeled-only
    /// form (`#Preview(body: { ... })`); both leave the label
    /// position empty.
    private func previewLabel(
        from arguments: LabeledExprListSyntax
    ) -> String? {
        guard let firstArg = arguments.first, firstArg.label == nil else {
            return nil
        }
        guard let literal = firstArg.expression
            .as(StringLiteralExprSyntax.self)
        else {
            return nil
        }
        return literal.segments
            .compactMap {
                $0.as(StringSegmentSyntax.self)?.content.text
            }
            .joined()
    }
}
