import Foundation
import SwiftParser
import SwiftSyntax

/// Walks every `.swift` file once and builds the symbol tables the analyzer
/// needs:
///   - `views` (every `struct/class : View` with its env requirements),
///   - `apps` (every `: App` declaration),
///   - `userKeypaths` (every `var name: ...` declared on
///     `extension EnvironmentValues`, minus those carrying the
///     `// swiftui-environment-audit: optional` marker — these are the
///     custom env keypaths the audit treats as required).
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
    /// Keypath names declared in any `extension EnvironmentValues` we
    /// scanned. Populated during `ingest`; used during `linkChildren` to
    /// decide which `@Environment(\.foo)` view declarations should be
    /// promoted to keypath requirements.
    var userKeypaths: Set<String> = []
    /// Keypaths whose declaration carried `// swiftui-environment-audit:
    /// optional`. Subtracted from `userKeypaths` before promotion.
    var optionalKeypaths: Set<String> = []
    /// Pending keypath references collected from `@Environment(\.foo)`
    /// view declarations. Resolved against `userKeypaths` /
    /// `optionalKeypaths` in `linkChildren` once every file has been
    /// ingested (declaration order isn't guaranteed).
    var rawKeypathRequirements: [String: [(keypath: String, line: Int, file: String)]] = [:]

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

    /// Cross-file finalize step. Runs after every file has been ingested:
    ///   - Resolves child constructor-call names against the known view set.
    ///   - Promotes `rawKeypathRequirements` to real `EnvRequirement`s for
    ///     keypaths the user actually declared and didn't opt out of.
    func linkChildren() {
        for (parent, calls) in rawChildCalls {
            guard var info = views[parent] else {
                continue
            }
            info.children = calls.intersection(views.keys)
            views[parent] = info
        }
        let required = userKeypaths.subtracting(optionalKeypaths)
        for (view, candidates) in rawKeypathRequirements {
            guard var info = views[view] else {
                continue
            }
            for candidate in candidates where required.contains(candidate.keypath) {
                info.requirements.append(
                    EnvRequirement(
                        kind: .keypath(candidate.keypath),
                        declaringView: view,
                        sourceFile: candidate.file,
                        line: candidate.line
                    )
                )
            }
            views[view] = info
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

    /// `extension EnvironmentValues { var someKey: ... }` — record each
    /// var binding's name as a user-declared keypath. Detect the
    /// `// swiftui-environment-audit: optional` marker on the var decl.
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.extendedType.trimmedDescription == "EnvironmentValues" else {
            return .visitChildren
        }
        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }
            let optional = hasOptionalMarker(in: varDecl.leadingTrivia)
            for binding in varDecl.bindings {
                guard let pattern = binding.pattern
                    .as(IdentifierPatternSyntax.self)
                else {
                    continue
                }
                let name = pattern.identifier.text
                catalogue.userKeypaths.insert(name)
                if optional {
                    catalogue.optionalKeypaths.insert(name)
                }
            }
        }
        return .visitChildren
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
                    handleEnvironmentAttribute(
                        attribute: attrSyntax,
                        info: &info
                    )
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

    /// `@Environment(SomeType.self)` → real type requirement, recorded now.
    /// `@Environment(\.someKey)`     → candidate keypath requirement,
    ///                                  promoted in `linkChildren` once the
    ///                                  full keypath catalogue is built.
    private func handleEnvironmentAttribute(
        attribute: AttributeSyntax,
        info: inout ViewInfo
    ) {
        guard let args = attribute.arguments?.as(LabeledExprListSyntax.self),
            let firstArg = args.first
        else {
            return
        }
        let line = converter.location(for: attribute.position).line
        if let memberAccess = firstArg.expression
            .as(MemberAccessExprSyntax.self),
            memberAccess.declName.baseName.text == "self",
            let base = memberAccess.base?.as(DeclReferenceExprSyntax.self)
        {
            info.requirements.append(
                EnvRequirement(
                    kind: .type(base.baseName.text),
                    declaringView: info.name,
                    sourceFile: file,
                    line: line
                )
            )
            return
        }
        if let keypath = firstArg.expression.as(KeyPathExprSyntax.self),
            let name = keypathName(keypath)
        {
            catalogue.rawKeypathRequirements[info.name, default: []].append(
                (keypath: name, line: line, file: file)
            )
        }
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
            kind: .type(typeName),
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

    private func hasOptionalMarker(in trivia: Trivia) -> Bool {
        for piece in trivia {
            switch piece {
            case .lineComment(let text), .blockComment(let text),
                .docLineComment(let text), .docBlockComment(let text):
                if text.contains("swiftui-environment-audit: optional") {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }
}

/// Pull the property name off `\.someKey` or `\EnvironmentValues.someKey`.
/// Returns nil for keypaths whose first non-base component isn't a plain
/// identifier (subscripts, optional chains).
func keypathName(_ keypath: KeyPathExprSyntax) -> String? {
    for component in keypath.components {
        if let property = component.component
            .as(KeyPathPropertyComponentSyntax.self)
        {
            return property.declName.baseName.text
        }
    }
    return nil
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
