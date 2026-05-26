/// Where a `RootInfo` came from. The audit walks two kinds of root
/// view trees the same way; the difference is only in the source —
/// Scenes always sit inside an `App` declaration, previews stand alone
/// as freestanding `#Preview` macro expansions and may carry a label.
enum RootOrigin {
    case scene(enclosingApp: String)
    case preview(label: String?)
}
