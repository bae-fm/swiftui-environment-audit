# swiftui-environment-audit

Static checker that finds SwiftUI root view trees missing the
`@Environment(SomeType.self)` injections their descendants require.

Two failure modes:

1. A root view tree — a `Scene { … }` or a `#Preview { … }` —
   whose descendants declare `@Environment(SomeType.self) var foo`
   will crash at render time if `SomeType` isn't anywhere in that
   tree's environment chain. There is no compile-time signal — the
   property wrapper traps on access. Previews are especially prone
   to this because their root is independent of the App's Scenes:
   every dependency the rendered view reads has to be injected from
   the preview body itself, and forgetting one only shows up the
   next time someone opens the canvas.

2. A view declaring `@Environment(\.someKey)` for a custom
   `EnvironmentKey` doesn't crash if missing — the key's `defaultValue`
   is used. But for custom application keys (analytics clients, API
   stubs, persistence services) the default is almost always a
   placeholder that's wrong in production. Silent no-ops are strictly
   worse than a crash.

This tool walks every `: App` in a source tree (each `Scene` inside
its body) and every freestanding `#Preview { ... }` macro, traces
each tree's view-instantiation graph, and reports:

- any `@Environment(SomeType.self)` / `@EnvironmentObject` requirement
  reachable from a root that the chain doesn't provide;
- any `@Environment(\.someKey)` requirement, where `\.someKey` is
  declared in the scanned source as a `var someKey` on
  `extension EnvironmentValues`, that the chain doesn't provide.

Both `.environment(value)` and `.environmentObject(value)` count as
provisions, including when they're applied through a custom
`extension View` modifier that bundles them:

```swift
extension View {
    func previewEnvironment() -> some View {
        self.environment(Store())
            .environment(\.analytics, AnalyticsClient.preview)
    }
}

#Preview { ContentView().previewEnvironment() }  // Store + \.analytics provided
```

A modifier that calls another such modifier inherits its provisions
(expanded transitively).

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
  `Scene { }` calls, `#Preview { }` macro expansions,
  `.environment(arg)` / `.environmentObject(arg)` modifiers, custom
  `extension View` env-bundle modifiers, and the local `let`/`if let`
  bindings inside root content closures. Generic-specialized view
  constructors (`Box<Inner>(…)`) are followed too: both the wrapper and
  each uppercase generic-argument type count as instantiated roots, so a
  store the wrapped content requires is checked against the chain.
- **Type resolution (IndexStoreDB)**: for each `.environment(arg)`, the
  source location of the arg's rightmost identifier is handed to the
  SourceKit index store the build produced. The compiler already
  resolved the whole expression at compile time; the index records the
  symbol it landed on. The canonical declaration's type is then read
  off the var decl with SwiftSyntax. When the symbol is a function
  (`.environment(makeStore())`, `.environment(PreviewData.someStore())`),
  its declared return type is used.
- **Local bindings**: Swift doesn't index references to local `let`
  bindings inside closures, so those are resolved separately by walking
  the closure's `if let X = expr` / `let X = expr` patterns and
  resolving each RHS through the same index lookup. A binding with an
  explicit type annotation (`let store: Store = { … }()`) is trusted
  directly — that resolves forms the index/AST can't see through, like
  an immediately-invoked closure.
- **Constructor calls**: `.environment(MyState())` is taken directly
  off the AST — the index would record `MyState` as a type symbol,
  not a property of that type. Previews routinely inline-construct
  their dependencies because there's no enclosing instance to hold
  them; this is the path that resolves those.

What this buys versus pure name matching: cross-file/module resolution,
no dependence on naming conventions, function-call argument types
(`.environment(makeService())`) become resolvable because the compiler
inferred them.

### Environment scope is a flat over-approximation

The walk credits every `.environment(...)` in a root's body to every
view that body instantiates, and treats every known-view constructor
in the body — including nested ones — as a separate root sharing that
one provision set. This is deliberate: env applied at an outer chain
(`Outer { Inner() }.environment(store)`) must satisfy the nested
`Inner`, and the shared set is what makes that work without modeling
the view tree.

The cost is one false-negative shape: env applied to a *sibling* of a
root (`VStack { RootA(); RootB().environment(store) }`) is credited to
`RootA` too, even though SwiftUI's environment doesn't flow across
siblings — so a missing injection on `RootA` can be silently accepted.
Distinguishing this from the legitimate nesting case requires modeling
the actual view-tree nesting, which the flat model discards; narrowing
it wrong would turn legitimate parent→child flow into false positives,
which erodes trust in a linter far more than this rare miss. The flat
model is kept on purpose. Apply preview/scene environment at the
outermost chain to stay inside what the audit checks.

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
  whose name matches a known view declaration, including the wrapper and
  the uppercase generic arguments of a generic-specialized call
  (`Box<Inner>(…)` follows both `Box` and `Inner`). Opaque-return views
  with conditional bodies, views passed as closure args, and generic
  content inferred rather than spelled out aren't all followed.
- Type extraction at the declaration site handles explicit annotations
  (`var foo: T`), constructor-call initializers (`var foo = T(...)`),
  and function return types (`func makeFoo() -> T`, including a `some`/
  `any` prefix stripped to `T`). Other inferred forms are reported as
  unresolved.
- A custom `extension View` env modifier is followed only when its env
  argument is a literal the resolver can see (`self.environment(Store())`).
  A modifier whose value comes from one of its own parameters can't be
  resolved statically and falls through to unresolved (conservative) —
  unless the parameter's name happens to match a `let` binding in the
  root that applies the modifier, in which case it resolves to that
  binding's type instead. Name your modifier parameters distinctly from
  root-local bindings if that matters.
- Environment scope is a flat over-approximation — see "Environment
  scope" under How it works for the one false-negative shape this
  trades for handling nested roots without modeling the view tree.
- Built-in SwiftUI keypaths (`\.colorScheme`, `\.dismiss`, `\.locale`,
  etc.) are ignored — their declarations are outside the scanned
  source. To audit a key, declare it on `extension EnvironmentValues`
  in code the tool sees.

## License

MIT
