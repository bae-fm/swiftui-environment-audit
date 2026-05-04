// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swiftui-environment-audit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "swiftui-environment-audit",
            targets: ["SwiftUIEnvironmentAudit"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            from: "603.0.1"
        ),
        .package(
            url: "https://github.com/apple/indexstore-db.git",
            revision: "swift-6.2.4-RELEASE"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SwiftUIEnvironmentAudit",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ]
        ),
    ]
)
