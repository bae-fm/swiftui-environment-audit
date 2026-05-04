// swift-tools-version: 5.9
import PackageDescription

// Two libraries that share the same shape: a SwiftUI App with a Settings
// scene whose tree includes a view requiring `@Environment(MyState.self)`.
// `Failing` doesn't inject MyState; `Passing` does. The audit run in CI
// asserts exit 1 on Failing and exit 0 on Passing.
let package = Package(
    name: "SampleApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Failing"),
        .target(name: "Passing"),
    ]
)
