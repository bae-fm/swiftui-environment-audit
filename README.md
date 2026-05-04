# swiftui-environment-audit

Static checker that finds SwiftUI Scene roots missing the
`@Environment(SomeType.self)` injections their descendants require.

A `Scene { … }` whose view tree contains a view declaring
`@Environment(SomeType.self) var foo` will crash at render time if
`SomeType` isn't anywhere in the scene's environment chain. There is no
compile-time signal — the property wrapper traps when the value is
accessed. Common previews that wrap inner content views also miss the
crash because they don't render through the same hierarchy.

This tool walks every `: App` in a source tree, traces each `Scene`'s
view-instantiation graph, collects every `@Environment(SomeType.self)`
and `@EnvironmentObject` reachable from a Scene root, and reports any
type that isn't provided by a `.environment(...)` modifier on the chain.

## How it works

- **AST shape (SwiftSyntax)**: discovers `: View`/`: App` declarations,
  `Scene { }` calls, `.environment(arg)` modifiers, and the local
  `let`/`if let` bindings inside scene closures.
- **Type resolution (IndexStoreDB)**: for each `.environment(arg)`, the
  source location of the arg's rightmost identifier is handed to the
  SourceKit index store the build produced. The compiler already
  resolved the whole expression at compile time; the index records the
  symbol it landed on. The canonical declaration's type is then read
  off the var decl with SwiftSyntax.
- **Local bindings**: Swift doesn't index references to local `let`
  bindings inside closures, so those are resolved separately by walking
  the closure's `if let X = expr` / `let X = expr` patterns and
  resolving each RHS through the same index lookup.

What this buys versus pure name matching: cross-file/module resolution,
no dependence on naming conventions, function-call argument types
(`.environment(makeService())`) become resolvable because the compiler
inferred them.

## Usage

```sh
swiftui-environment-audit \
  --index-store-path PATH/Index.noindex/DataStore \
  Sources/
```

`--index-store-path` is required. Where to find it:

- **Xcode project**: `xcodebuild ... -derivedDataPath PATH build` →
  index store at `PATH/Index.noindex/DataStore`.
- **SwiftPM**: `swift build -Xswiftc -index-store-path -Xswiftc PATH` →
  index store at `PATH`.

`--lib-index-store` defaults to the active Xcode toolchain
(`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib`).
Override only when running against a non-Xcode toolchain.

Positional arguments are directories or `.swift` files to scan.

## Exit codes

| code | meaning                                                      |
|------|--------------------------------------------------------------|
| 0    | no missing-environment findings                              |
| 1    | one or more findings (each printed with chain to the cause)  |
| 64   | usage error (missing args, `--help`)                         |
| 66   | path doesn't exist (positional arg or index store)           |
| 70   | failed to load `libIndexStore.dylib` or open the index store |

## Installation

Pre-built macOS arm64 binary on each release:

```sh
curl -L https://github.com/bae-fm/swiftui-environment-audit/releases/latest/download/swiftui-environment-audit-vX.Y.Z-macos-arm64.tar.gz \
  | tar -xz -C /usr/local/bin
```

Or build from source:

```sh
git clone https://github.com/bae-fm/swiftui-environment-audit.git
cd swiftui-environment-audit
swift build -c release
# binary at .build/release/swiftui-environment-audit
```

## Limitations

- Only macOS arm64 binaries published. SwiftUI is Apple-only anyway, but
  if you need x86_64 build from source.
- View-instantiation graph is heuristic: it follows constructor calls
  whose name matches a known view declaration. Generic wrappers
  (`Wrapper<ContentView>`), opaque-return views with conditional
  bodies, and views passed as closure args aren't all followed.
- Type extraction at the declaration site handles explicit annotations
  (`var foo: T`) and constructor-call initializers (`var foo = T(...)`).
  Other inferred forms are reported as unresolved.
- `@Environment(\.someKey)` (the `EnvironmentKey`/keypath form) is
  intentionally skipped — those have a `defaultValue` and don't crash
  when missing.

## License

MIT
