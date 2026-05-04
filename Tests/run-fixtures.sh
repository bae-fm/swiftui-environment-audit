#!/usr/bin/env bash
# Fixture-based smoke test for the audit binary. Exits non-zero on any
# unexpected outcome. Invoked by CI; runnable locally too.
#
# Builds the SampleApp fixtures with `swift build -index-store-path`,
# then asserts:
#   - exit 1 on the Failing target with a finding for `MyState`
#   - exit 0 on the Passing target with no findings.

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

echo "=== Failing fixture (expect exit 1, finding for MyState) ==="
set +e
"$binary" --index-store-path "$idx" Sources/Failing > /tmp/audit-failing.txt 2>&1
failing_exit=$?
set -e
cat /tmp/audit-failing.txt
if [[ $failing_exit -ne 1 ]]; then
    echo "FAIL: expected exit 1, got $failing_exit" >&2
    exit 1
fi
if ! grep -q "is missing MyState" /tmp/audit-failing.txt; then
    echo "FAIL: expected 'is missing MyState' in output" >&2
    exit 1
fi
if ! grep -q "chain: SettingsRoot → Inner" /tmp/audit-failing.txt; then
    echo "FAIL: expected 'chain: SettingsRoot → Inner' in output" >&2
    exit 1
fi

echo
echo "=== Passing fixture (expect exit 0) ==="
set +e
"$binary" --index-store-path "$idx" Sources/Passing > /tmp/audit-passing.txt 2>&1
passing_exit=$?
set -e
cat /tmp/audit-passing.txt
if [[ $passing_exit -ne 0 ]]; then
    echo "FAIL: expected exit 0, got $passing_exit" >&2
    exit 1
fi
if ! grep -q "No missing-environment findings" /tmp/audit-passing.txt; then
    echo "FAIL: expected 'No missing-environment findings' in output" >&2
    exit 1
fi

echo
echo "All fixtures passed."
