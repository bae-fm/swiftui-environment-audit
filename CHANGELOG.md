# Changelog

## v0.4.0

Widen the resolver so more real preview/scene environment shapes are
recognized instead of being reported as missing.

- Custom `extension View` env-bundle modifiers: applying a modifier whose
  body calls `.environment(…)` / `.environmentObject(…)` now counts as
  providing those values. Modifiers that call other such modifiers inherit
  their provisions (expanded transitively).
- `.environmentObject(value)` is now recognized as a provision (matching
  the existing `@EnvironmentObject` requirement detection).
- Local bindings with an explicit type annotation
  (`let store: Store = { … }()`) resolve from the annotation, so an
  immediately-invoked closure the index/AST can't see through still
  resolves.
- Function return types resolve: `.environment(makeStore())` and
  `.environment(PreviewData.someStore())` use the function's declared
  return type (a `some`/`any` prefix is stripped to the underlying type).
- Generic-specialized view instantiations (`Box<Inner>(…)`) are followed
  for both the wrapper and each uppercase generic-argument type, so a
  store the wrapped content requires is checked against the chain.

Unchanged on purpose: environment scope remains a flat over-approximation.
Crediting every `.environment(…)` in a body to every instantiated root is
what lets env applied at an outer chain satisfy nested roots; narrowing it
would require modeling the view tree and risks false positives. See the
README "Environment scope" note for the one false-negative shape this
trades for that.
