#!/usr/bin/env bash
# Fixture-based smoke test for the audit binary. Exits non-zero on any
# unexpected outcome. Invoked by CI; runnable locally too.
#
# Builds the SampleApp fixtures with `swift build -index-store-path`,
# then asserts:
#   - Failing target: exit 1, with findings for the type-form requirement
#     (MyState) and the keypath-form requirement (\.analytics) both
#     pinned to the SettingsRoot → Inner chain, plus a preview-rooted
#     finding chained directly to Inner. Plus two resolver-enhancement
#     negatives: a custom env-bundle modifier that omits StoreB (so
#     StoreB is still reported), and a generic-wrapped inner whose
#     BoxedStore is never injected (proving the wrapper's inner
#     requirement is seen).
#   - Passing target: exit 0. Inner also requires \.uiTheme but that key
#     carries the optional marker, so the audit ignores it. Includes a
#     preview that injects every required value, plus previews that
#     exercise each resolver enhancement (custom env-bundle modifier and
#     its transitive wrapper, type-annotated IIFE local, function-return
#     type, .environmentObject provision, generic wrapper) — none may
#     raise a finding.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$repo_root/.build/release/swiftui-environment-audit"

if [[ ! -x "$binary" ]]; then
    echo "error: $binary not found — run 'swift build -c release' first" >&2
    exit 1
fi

cd "$repo_root/Tests/Fixtures/SampleApp"
idx="$PWD/.build/idx"
swift build -Xswiftc -index-store-path -Xswiftc "$idx" >/dev/null

assert_contains() {
    local needle="$1"
    local file="$2"
    if ! grep -qF "$needle" "$file"; then
        echo "FAIL: expected '$needle' in $file" >&2
        exit 1
    fi
}

echo "=== Failing fixture (expect exit 1, MyState + \\.analytics findings) ==="
set +e
"$binary" --index-store-path "$idx" Sources/Failing > /tmp/audit-failing.txt 2>&1
failing_exit=$?
set -e
cat /tmp/audit-failing.txt
if [[ $failing_exit -ne 1 ]]; then
    echo "FAIL: expected exit 1, got $failing_exit" >&2
    exit 1
fi
assert_contains "is missing MyState" /tmp/audit-failing.txt
assert_contains "is missing \.analytics" /tmp/audit-failing.txt
assert_contains "chain: SettingsRoot → Inner" /tmp/audit-failing.txt
assert_contains "Preview 'Failing Inner'" /tmp/audit-failing.txt
assert_contains "chain: Inner" /tmp/audit-failing.txt
# #1: custom env-bundle modifier injects StoreA but omits StoreB, so the
# expansion must not blanket-satisfy — StoreB is still missing.
assert_contains "Preview 'Partial bundle'" /tmp/audit-failing.txt
assert_contains "is missing StoreB" /tmp/audit-failing.txt
# #4: the generic-wrapped inner's requirement must be seen and reported.
assert_contains "Preview 'Generic wrapper missing env'" /tmp/audit-failing.txt
assert_contains "is missing BoxedStore" /tmp/audit-failing.txt
assert_contains "chain: BoxedInner" /tmp/audit-failing.txt
# #4: the spelled `Box<SpecInner>(content:)` form exercises the
# generic-argument extraction (SpecInner appears only as the generic arg,
# not as a nested call), so its SpecStore requirement must surface.
assert_contains "Preview 'Spelled generic missing env'" /tmp/audit-failing.txt
assert_contains "is missing SpecStore" /tmp/audit-failing.txt
assert_contains "chain: SpecInner" /tmp/audit-failing.txt
# #1: StoreA was provided through the modifier, so it must NOT be reported.
if grep -qF "is missing StoreA" /tmp/audit-failing.txt; then
    echo "FAIL: StoreA was provided via .partialPreviewEnvironment() but reported missing" >&2
    exit 1
fi

echo
echo "=== Passing fixture (expect exit 0; \\.uiTheme is opt-out) ==="
set +e
"$binary" --index-store-path "$idx" Sources/Passing > /tmp/audit-passing.txt 2>&1
passing_exit=$?
set -e
cat /tmp/audit-passing.txt
if [[ $passing_exit -ne 0 ]]; then
    echo "FAIL: expected exit 0, got $passing_exit" >&2
    exit 1
fi
assert_contains "No missing-environment findings" /tmp/audit-passing.txt
# Exit 0 already proves none of the enhancement previews raised a finding.
# These assert the resolutions actually happened (not that the requirements
# were silently dropped), so a regression that stops resolving a form turns
# into a finding or a changed line here rather than passing by accident.
# #1 custom env-bundle modifier: both stores resolved through the modifier.
assert_contains "preview: 'Bundle modifier'" /tmp/audit-passing.txt
assert_contains "StoreA() → StoreA" /tmp/audit-passing.txt
assert_contains "StoreB() → StoreB" /tmp/audit-passing.txt
# #1 transitive: the wrapper modifier inherits the bundle's provisions.
assert_contains "preview: 'Transitive bundle modifier'" /tmp/audit-passing.txt
# #2 type-annotated IIFE local binding.
assert_contains "store → AnnotatedStore" /tmp/audit-passing.txt
# #3/#5 function return type.
assert_contains "makeFactoryStore() → FactoryStore" /tmp/audit-passing.txt
# #7 .environmentObject provision.
assert_contains "LegacyStore() → LegacyStore" /tmp/audit-passing.txt
# #4 generic wrapper (trailing closure): inner seen as a root, store resolved.
assert_contains "BoxedStore() → BoxedStore" /tmp/audit-passing.txt
# #4 spelled `Box<SpecInner>(content:)`: the generic-argument extraction
# surfaces SpecInner (it's not a nested call here), and its store resolves.
assert_contains "preview: 'Spelled generic specialization'" /tmp/audit-passing.txt
assert_contains "SpecStore() → SpecStore" /tmp/audit-passing.txt

echo
echo "All fixtures passed."
