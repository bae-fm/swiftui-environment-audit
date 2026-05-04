/// Two failure modes the audit catches:
///
///   - `.type(SomeType)`  — `@Environment(SomeType.self)` (the @Observable
///                           form, iOS 17+) and `@EnvironmentObject`. Both
///                           crash at render time when the type is missing
///                           from the environment chain.
///   - `.keypath(name)`   — `@Environment(\.someKey)` where `someKey` is a
///                           custom `EnvironmentKey` declared in the
///                           scanned source. These don't crash if missing
///                           (the key's `defaultValue` is used) but the
///                           default is almost always a placeholder for
///                           services/dependencies. The audit treats every
///                           user-declared key as required unless its
///                           `extension EnvironmentValues` property
///                           carries an `// swiftui-environment-audit:
///                           optional` marker.
enum EnvKind: Hashable {
    case type(String)
    case keypath(String)

    var description: String {
        switch self {
        case .type(let name):
            return name
        case .keypath(let name):
            return "\\.\(name)"
        }
    }
}

struct EnvRequirement: Hashable {
    let kind: EnvKind
    let declaringView: String
    let sourceFile: String
    let line: Int
}
