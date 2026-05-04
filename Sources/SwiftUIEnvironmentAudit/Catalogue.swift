import Foundation
import SwiftParser
import SwiftSyntax

/// Walks every `.swift` file once and builds the symbol tables the analyzer
/// needs: `views` (every `struct/class : View` with its env requirements),
/// and `apps` (every `: App` declaration).
///
/// We deliberately do *not* maintain a property/type catalogue here — type
/// resolution happens later via `IndexResolver`, which queries the
/// SourceKit index for ground-truth types. This keeps `Catalogue` focused
/// on AST-shape questions only.
final class Catalogue {
    var views: [String: ViewInfo] = [:]
    var apps: Set<String> = []
    /// Raw constructor-call names observed inside each view's body. Resolved
    /// against `views.keys` later to populate `ViewInfo.children`.
    var rawChildCalls: [String: Set<String>] = [:]

    func ingest(file: URL) throws {
        let source = try String(contentsOf: file, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(
            fileName: file.path,
            tree: tree
        )
        let visitor = TopLevelVisitor(
            file: file.path,
            converter: converter,
            catalogue: self
        )
        visitor.walk(tree)
    }

    /// Resolve raw constructor-call names against the known view set so each
    /// `ViewInfo.children` only points at declarations we've actually seen.
    func linkChildren() {
        for (parent, calls) in rawChildCalls {
            guard var info = views[parent] else {
                continue
            }
            info.children = calls.intersection(views.keys)
            views[parent] = info
        }
    }
}

private final class TopLevelVisitor: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    let catalogue: Catalogue
    private var typeStack: [String] = []

    init(file: String, converter: SourceLocationConverter, catalogue: Catalogue) {
        self.file = file
        self.converter = converter
        self.catalogue = catalogue
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(
            name: node.name.text,
            inheritance: node.inheritanceClause,
            members: node.memberBlock.members,
            startToken: node.name
        )
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        typeStack.removeLast()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(
            name: node.name.text,
            inheritance: node.inheritanceClause,
            members: node.memberBlock.members,
            startToken: node.name
        )
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        typeStack.removeLast()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(
            name: node.name.text,
            inheritance: node.inheritanceClause,
            members: node.memberBlock.members,
            startToken: node.name
        )
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        typeStack.removeLast()
    }

    private func enterType(
        name: String,
        inheritance: InheritanceClauseSyntax?,
        members: MemberBlockItemListSyntax,
        startToken: TokenSyntax
    ) {
        typeStack.append(name)
        let conformances = inheritance?.inheritedTypes
            .map { $0.type.trimmedDescription } ?? []
        if conformances.contains("App") {
            catalogue.apps.insert(name)
        }
        if conformances.contains("View") {
            let line = converter.location(for: startToken.position).line
            var info = ViewInfo(name: name, sourceFile: file, line: line)
            collectRequirements(in: members, into: &info)
            catalogue.views[name] = info
            collectChildCalls(in: members, parent: name)
        }
    }

    private func collectRequirements(
        in members: MemberBlockItemListSyntax,
        into info: inout ViewInfo
    ) {
        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }
            for attr in varDecl.attributes {
                guard let attrSyntax = attr.as(AttributeSyntax.self) else {
                    continue
                }
                let attrName = attrSyntax.attributeName.trimmedDescription
                if attrName == "Environment" {
                    if let req = parseEnvironmentAttribute(
                        attribute: attrSyntax,
                        viewName: info.name
                    ) {
                        info.requirements.append(req)
                    }
                }
                else if attrName == "EnvironmentObject" {
                    if let req = parseEnvironmentObjectBinding(
                        binding: varDecl.bindings.first,
                        viewName: info.name
                    ) {
                        info.requirements.append(req)
                    }
                }
            }
        }
    }

    private func parseEnvironmentAttribute(
        attribute: AttributeSyntax,
        viewName: String
    ) -> EnvRequirement? {
        guard let args = attribute.arguments?.as(LabeledExprListSyntax.self),
            let firstArg = args.first
        else {
            return nil
        }
        // `@Environment(SomeType.self)` — the @Observable form. Crashes if
        // missing. The argument is a member-access expression with `.self`.
        if let memberAccess = firstArg.expression
            .as(MemberAccessExprSyntax.self),
            memberAccess.declName.baseName.text == "self",
            let base = memberAccess.base?.as(DeclReferenceExprSyntax.self)
        {
            let line = converter.location(for: attribute.position).line
            return EnvRequirement(
                typeName: base.baseName.text,
                declaringView: viewName,
                sourceFile: file,
                line: line
            )
        }
        // `@Environment(\.someKey)` — keypath form. Resolves to an
        // `EnvironmentKey` with a `defaultValue`, so it does not crash.
        return nil
    }

    private func parseEnvironmentObjectBinding(
        binding: PatternBindingSyntax?,
        viewName: String
    ) -> EnvRequirement? {
        guard let binding,
            let typeAnnotation = binding.typeAnnotation
        else {
            return nil
        }
        let typeName = typeAnnotation.type.trimmedDescription
        let line = converter.location(for: binding.position).line
        return EnvRequirement(
            typeName: typeName,
            declaringView: viewName,
            sourceFile: file,
            line: line
        )
    }

    private func collectChildCalls(
        in members: MemberBlockItemListSyntax,
        parent: String
    ) {
        var calls = catalogue.rawChildCalls[parent] ?? []
        let scout = ConstructorCallScout()
        for member in members {
            scout.walk(member)
        }
        calls.formUnion(scout.calls)
        catalogue.rawChildCalls[parent] = calls
    }
}

/// Collects every uppercase-named `IdentifierExpr(...)` call from a syntax
/// subtree. Names are resolved against the known view set later.
private final class ConstructorCallScout: SyntaxVisitor {
    var calls: Set<String> = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(
        _ node: FunctionCallExprSyntax
    ) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression
            .as(DeclReferenceExprSyntax.self)
        {
            let name = callee.baseName.text
            if name.first?.isUppercase == true {
                calls.insert(name)
            }
        }
        return .visitChildren
    }
}
