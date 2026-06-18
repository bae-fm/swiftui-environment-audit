import Foundation
import IndexStoreDB

/// CLI: `swiftui-environment-audit --index-store-path PATH [--lib-index-store PATH] PATH …`
///
/// `--index-store-path` is required. It points at the SourceKit index
/// store the build produced. For an Xcode project built with
/// `-derivedDataPath PATH`, that's `PATH/Index.noindex/DataStore`. For a
/// SwiftPM build with `-Xswiftc -index-store-path -Xswiftc PATH`, it's
/// `PATH`.
///
/// `--lib-index-store` defaults to the path inside the active Xcode
/// toolchain. Override only when running against a non-Xcode toolchain.
///
/// The remaining positional arguments are directories or files to scan
/// for views, Scene roots, and `#Preview` macro roots. The scan source
/// set and the index don't have to overlap exactly, but env-requirement
/// detection only sees views inside the scan set.

struct CLIOptions {
    var indexStorePath: String?
    var libIndexStorePath: String =
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
    var paths: [String] = []
}

func usage() -> Never {
    let msg = """
        usage: swiftui-environment-audit --index-store-path PATH [options] PATH …

        Options:
          --index-store-path PATH   SourceKit index store directory
                                    (e.g. .build/derivedData/Index.noindex/DataStore)
          --lib-index-store PATH    libIndexStore.dylib path
                                    (default: active Xcode toolchain)

        Positional arguments are directories or .swift files to scan for
        views, Scene roots, and #Preview macro roots. Exit code is 1 if
        any missing-environment finding is reported, 0 otherwise.

        """
    FileHandle.standardError.write(Data(msg.utf8))
    exit(64)
}

func parseArgs(_ raw: [String]) -> CLIOptions {
    var opts = CLIOptions()
    var i = 0
    while i < raw.count {
        let arg = raw[i]
        switch arg {
        case "--index-store-path":
            i += 1
            guard i < raw.count else {
                usage()
            }
            opts.indexStorePath = raw[i]
        case "--lib-index-store":
            i += 1
            guard i < raw.count else {
                usage()
            }
            opts.libIndexStorePath = raw[i]
        case "-h", "--help":
            usage()
        default:
            opts.paths.append(arg)
        }
        i += 1
    }
    return opts
}

let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))
guard let indexStorePath = opts.indexStorePath, !opts.paths.isEmpty else {
    usage()
}
guard FileManager.default.fileExists(atPath: indexStorePath) else {
    FileHandle.standardError.write(
        Data(
            """
            error: index store not found at \(indexStorePath)
              build first:
                xcodebuild ... -derivedDataPath PATH      (then PATH/Index.noindex/DataStore)
                swift build -Xswiftc -index-store-path -Xswiftc PATH

            """
                .utf8
        )
    )
    exit(66)
}

let library: IndexStoreLibrary
do {
    library = try IndexStoreLibrary(dylibPath: opts.libIndexStorePath)
}
catch {
    FileHandle.standardError.write(
        Data(
            "error: failed to load \(opts.libIndexStorePath): \(error)\n".utf8
        )
    )
    exit(70)
}

let dbPath = NSTemporaryDirectory()
    + "swiftui-environment-audit-\(UUID().uuidString)"
let index: IndexStoreDB
do {
    index = try IndexStoreDB(
        storePath: indexStorePath,
        databasePath: dbPath,
        library: library,
        waitUntilDoneInitializing: true
    )
}
catch {
    FileHandle.standardError.write(
        Data("error: failed to open index at \(indexStorePath): \(error)\n".utf8)
    )
    exit(70)
}
// dbPath is inside NSTemporaryDirectory(); macOS reaps it. Manual cleanup
// would race with IndexStoreDB's background work and add a failure mode
// that's worse than the leak.

let fileManager = FileManager.default
var swiftFiles: [URL] = []
for arg in opts.paths {
    let url = URL(fileURLWithPath: arg)
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
        FileHandle.standardError.write(
            Data("error: path does not exist: \(arg)\n".utf8)
        )
        exit(66)
    }
    if isDir.boolValue {
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let next = enumerator?.nextObject() as? URL {
            if next.pathExtension == "swift" {
                swiftFiles.append(next)
            }
        }
    }
    else if url.pathExtension == "swift" {
        swiftFiles.append(url)
    }
}

let catalogue = Catalogue()
for file in swiftFiles {
    do {
        try catalogue.ingest(file: file)
    }
    catch {
        FileHandle.standardError.write(
            Data("warning: failed to parse \(file.path): \(error)\n".utf8)
        )
    }
}
catalogue.linkChildren()
catalogue.linkModifiers()

let resolver = IndexResolver(index: index)
let sceneCollector = SceneCollector(catalogue: catalogue, resolver: resolver)
let previewCollector = PreviewCollector(catalogue: catalogue, resolver: resolver)
for file in swiftFiles {
    do {
        try sceneCollector.ingest(file: file)
        try previewCollector.ingest(file: file)
    }
    catch {
        FileHandle.standardError.write(
            Data("warning: failed to parse \(file.path): \(error)\n".utf8)
        )
    }
}

let roots = sceneCollector.roots + previewCollector.roots
let analyzer = Analyzer(catalogue: catalogue, roots: roots)
let findings = analyzer.findings()

print("Scanned \(swiftFiles.count) Swift files.")
print(
    "Catalogued \(catalogue.views.count) views, \(catalogue.apps.count) App declarations, \(sceneCollector.roots.count) scenes, \(previewCollector.roots.count) previews."
)
print("")

/// Heading line for a root: discriminates scene vs preview and adds
/// the preview label when present.
func heading(for root: RootInfo) -> String {
    switch root.origin {
    case .scene:
        return "scene: \(root.kind) at \(root.sourceFile):\(root.line)"
    case .preview(let label):
        let labelPart = label.map { " '\($0)'" } ?? ""
        return "preview:\(labelPart) at \(root.sourceFile):\(root.line)"
    }
}

/// Identifier used in finding output. The per-root listing uses
/// `heading(for:)`; findings refer back to the same root with this
/// shorter form so reports stay grep-able.
func findingHeading(for root: RootInfo) -> String {
    switch root.origin {
    case .scene:
        return root.kind
    case .preview(let label):
        return label.map { "Preview '\($0)'" } ?? "Preview"
    }
}

for root in roots {
    print(heading(for: root))
    switch root.origin {
    case .scene(let enclosingApp):
        print("  enclosing App: \(enclosingApp)")
    case .preview:
        break
    }
    print("  roots: \(root.rootViews.sorted().joined(separator: ", "))")
    if !root.localBindings.isEmpty {
        print("  local bindings:")
        for (name, type) in root.localBindings.sorted(by: { $0.key < $1.key }) {
            print("    \(name): \(type)")
        }
    }
    if root.providedExpressions.isEmpty && root.providedKeypaths.isEmpty {
        print("  provided: (none)")
    }
    else {
        print("  provided expressions:")
        for expr in root.providedExpressions {
            let resolved = resolver.resolve(
                expression: expr,
                bindings: root.localBindings
            ) ?? "<unresolved>"
            print("    \(expr.text) → \(resolved)")
        }
        for keypath in root.providedKeypaths.sorted() {
            print("    \\.\(keypath)")
        }
    }
    print("")
}

if findings.isEmpty {
    print("No missing-environment findings.")
    exit(0)
}

print("Findings (\(findings.count)):")
for finding in findings {
    print("")
    print(
        "  ✗ \(findingHeading(for: finding.root)) at \(finding.root.sourceFile):\(finding.root.line) is missing \(finding.requirement.kind.description)"
    )
    print(
        "    required by \(finding.requirement.declaringView) (\(finding.requirement.sourceFile):\(finding.requirement.line))"
    )
    print("    chain: \(finding.path.joined(separator: " → "))")
}
exit(1)
