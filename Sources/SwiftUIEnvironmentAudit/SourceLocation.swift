/// A position in a source file. Mirrors `IndexStoreDB.SymbolLocation`'s
/// 1-based line and 1-based UTF-8 column convention so the resolver can
/// hand it directly to the index.
struct SourceLocation: Hashable {
    let file: String
    let line: Int
    let utf8Column: Int
}
