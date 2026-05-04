# swiftui-environment-audit

Static checker that finds SwiftUI Scene roots missing the
`@Environment(SomeType.self)` injections their descendants require.

Two failure modes:

1. A `Scene { … }` whose view tree contains a view declaring
   `@Environment(SomeType.self) var foo` will crash at render time if
   `SomeType` isn't anywhere in the scene's environment chain. There is
   no compile-time signal — the property wrapper traps on access.
   Common previews that wrap inner content views also miss the crash
   because they don't render through the same hierarchy.

2. A view declaring `@Environment(\.someKey)` for a custom
   `EnvironmentKey` doesn't crash if missing — the key's `defaultValue`
   is used. But for custom application keys (analytics clients, API
   stubs, persistence services) the default is almost always a
   placeholder that's wrong in production. Silent no-ops are strictly
   worse than a crash.

This tool walks every `: App` in a source tree, traces each `Scene`'s
view-instantiation graph, and reports:

- any `@Environment(SomeType.self)` / `@EnvironmentObject` requirement
  reachable from a Scene root that the chain doesn't provide;
- any `@Environment(\.someKey)` requirement, where `\.someKey` is
  declared in the scanned source as a `var someKey` on
  `extension EnvironmentValues`, that the chain doesn't provide.

Framework keypaths (`\.colorScheme`, `\.dismiss`, `\.locale`, etc.) are
ignored automatically — their declarations live outside the scanned
source. Per-key opt-out via comment marker is supported for any
custom key whose `defaultValue` really is the production value:

```swift
extension EnvironmentValues {
    // swiftui-environment-audit: optional
    var lineLimit: Int? {
        get { self[LineLimitKey.self] }
        set { self[LineLimitKey.self] = newValue }
    }
}
```

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
- Built-in SwiftUI keypaths (`\.colorScheme`, `\.dismiss`, `\.locale`,
  etc.) are ignored — their declarations are outside the scanned
  source. To audit a key, declare it on `extension EnvironmentValues`
  in code the tool sees.

## License

MIT
