#!/usr/bin/env bash
# Fixture-based smoke test for the audit binary. Exits non-zero on any
# unexpected outcome. Invoked by CI; runnable locally too.
#
# Builds the SampleApp fixtures with `swift build -index-store-path`,
# then asserts:
#   - Failing target: exit 1, with findings for the type-form requirement
#     (MyState) and the keypath-form requirement (\.analytics) both
#     pinned to the SettingsRoot → Inner chain.
#   - Passing target: exit 0. Inner also requires \.uiTheme but that key
#     carries the optional marker, so the audit ignores it.

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

echo
echo "All fixtures passed."
