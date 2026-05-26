import Foundation
import IndexStoreDB
import SwiftParser
import SwiftSyntax

/// Resolves expression types using the SourceKit index store produced by
/// the project's `xcodebuild` (the same store Periphery reads from).
///
/// Strategy per expression:
///   1. If a single-identifier expression matches a local binding the
///      caller already collected, return that binding's type. (Local
///      `let` / `if let` bindings are not indexed by the Swift compiler,
///      so we can't ask the index for them.)
///   2. Otherwise look up the symbol occurrence at the rightmost
///      identifier's source location. The compiler already resolved the
///      whole property chain at compile time; the index records the symbol
///      it landed on (e.g. `AppDelegate.uiState`).
///   3. Find that symbol's canonical declaration occurrence, parse the
///      file at that location with SwiftSyntax, and read off the
///      property's type — either from its annotation or, when the type is
///      inferred, from a constructor-call initializer.
final class IndexResolver {
    private let index: IndexStoreDB
    /// Parsed-file cache, since the same files get hit repeatedly when a
    /// codebase has lots of properties pointing at the same handful of
    /// types (`AppService`, `AppStore`, `LibraryStore`).
    private var parsedFiles: [String: (SourceFileSyntax, SourceLocationConverter)] = [:]

    init(index: IndexStoreDB) {
        self.index = index
    }

    func resolve(
        expression: ResolvableExpression,
        bindings: [String: String]
    ) -> String? {
        // Local-binding fast path. `text` is the raw source so it works
        // for bare identifiers regardless of whether we managed to capture
        // an identifierLocation.
        let trimmed = expression.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if isPlainIdentifier(trimmed), let bound = bindings[trimmed] {
            return bound
        }
        // AST-side fast path for `T(...)` constructor calls — the
        // index records `T` as a type symbol, not a property of type
        // `T`, so `propertyType(forUSR:)` would return nil for the
        // common preview shape `.environment(MyState())`.
        if let ctor = expression.constructorType {
            return ctor
        }
        guard let location = expression.identifierLocation else {
            return nil
        }
        guard let occurrence = referenceOccurrence(at: location) else {
            return nil
        }
        return propertyType(forUSR: occurrence.symbol.usr)
    }

    /// Find the reference occurrence at a precise file:line:column. The
    /// indexer can record multiple occurrences at a single position (the
    /// reference itself plus an implicit getter call); we want the
    /// concrete property/declaration reference.
    private func referenceOccurrence(at location: SourceLocation) -> SymbolOccurrence? {
        let candidates = index.symbolOccurrences(inFilePath: location.file)
            .filter {
                $0.location.line == location.line
                    && $0.location.utf8Column == location.utf8Column
                    && $0.roles.contains(.reference)
            }
        // Prefer a reference that isn't an implicit accessor call. The
        // implicit getters reuse the same source location but are tagged
        // with `.implicit`.
        return candidates.first(where: { !$0.roles.contains(.implicit) })
            ?? candidates.first
    }

    /// Walk the canonical declaration of `usr` and return the property's
    /// declared type. The index gives us the file/line of the declaration;
    /// SwiftSyntax does the type extraction.
    private func propertyType(forUSR usr: String) -> String? {
        let definitions = index.occurrences(
            ofUSR: usr,
            roles: [.definition, .declaration]
        )
        for definition in definitions {
            if let type = extractType(at: definition.location) {
                return type
            }
        }
        return nil
    }

    private func extractType(at location: SymbolLocation) -> String? {
        guard let (tree, _) = parseFile(path: location.path) else {
            return nil
        }
        let finder = VariableDeclFinder(
            line: location.line,
            utf8Column: location.utf8Column,
            converter: SourceLocationConverter(
                fileName: location.path,
                tree: tree
            )
        )
        finder.walk(tree)
        return finder.foundType
    }

    private func parseFile(
        path: String
    ) -> (SourceFileSyntax, SourceLocationConverter)? {
        if let cached = parsedFiles[path] {
            return cached
        }
        let source: String
        do {
            source = try String(contentsOfFile: path, encoding: .utf8)
        }
        catch {
            FileHandle.standardError.write(
                Data(
                    "warning: failed to read \(path) for type extraction: \(error)\n"
                        .utf8
                )
            )
            return nil
        }
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let pair = (tree, converter)
        parsedFiles[path] = pair
        return pair
    }

    private func isPlainIdentifier(_ s: String) -> Bool {
        guard let first = s.first else {
            return false
        }
        return (first.isLetter || first == "_")
            && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// Locates the variable declaration whose binding's identifier sits at a
/// given line/column, then extracts the bound type. Handles two cases the
/// codebase actually uses:
///   - explicit `var foo: SomeType` annotations,
///   - inferred `var foo = SomeType(...)` initializers (constructor-call).
/// Other inferred forms (`var foo = compute()`) are out of scope here —
/// callers see nil and bias toward over-reporting rather than wrong
/// answers.
private final class VariableDeclFinder: SyntaxVisitor {
    let line: Int
    let utf8Column: Int
    let converter: SourceLocationConverter
    var foundType: String?

    init(line: Int, utf8Column: Int, converter: SourceLocationConverter) {
        self.line = line
        self.utf8Column = utf8Column
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(
        _ node: PatternBindingSyntax
    ) -> SyntaxVisitorContinueKind {
        guard let pattern = node.pattern.as(IdentifierPatternSyntax.self)
        else {
            return .visitChildren
        }
        let loc = converter.location(for: pattern.identifier.position)
        if loc.line != line || loc.column != utf8Column {
            return .visitChildren
        }
        if let annotation = node.typeAnnotation {
            foundType = stripOptional(annotation.type.trimmedDescription)
            return .skipChildren
        }
        if let initializer = node.initializer,
            let call = initializer.value.as(FunctionCallExprSyntax.self),
            let callee = call.calledExpression
                .as(DeclReferenceExprSyntax.self)
        {
            foundType = callee.baseName.text
            return .skipChildren
        }
        return .skipChildren
    }

    /// `AppService?` → `AppService`, `Foo!` → `Foo`. The optional wrapper
    /// is irrelevant to whether the env requirement is satisfied — what
    /// matters is the underlying type SwiftUI sees in the environment.
    private func stripOptional(_ type: String) -> String {
        var t = type
        while t.last == "?" || t.last == "!" {
            t.removeLast()
        }
        return t
    }
}
