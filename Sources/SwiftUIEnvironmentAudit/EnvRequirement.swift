/// A type that an `@Environment(...)` declaration requires (the `@Observable`
/// form, iOS 17+) or that an `@EnvironmentObject` declaration requires.
/// Both crash the app at render time when the value isn't present in the
/// environment, which is the class of bug this tool exists to catch.
struct EnvRequirement: Hashable {
    let typeName: String
    let declaringView: String
    let sourceFile: String
    let line: Int
}
