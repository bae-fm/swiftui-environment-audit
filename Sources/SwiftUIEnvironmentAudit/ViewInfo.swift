/// Everything we know about a SwiftUI view declaration.
struct ViewInfo {
    let name: String
    let sourceFile: String
    let line: Int
    /// `@Environment(SomeType.self)` and `@EnvironmentObject` declarations.
    var requirements: [EnvRequirement] = []
    /// Names of other view types this view's body constructs. Used to walk
    /// the transitive view-instantiation graph.
    var children: Set<String> = []
}
