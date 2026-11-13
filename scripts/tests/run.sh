#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Self-tests for the design scripts: contrast verdicts, generator determinism, id drift checks.
set -eu
cd "$(dirname "$0")/../.."

failures=0
tmp="design/build/tests"
mkdir -p "$tmp"

expect_exit() {
    expected=$1
    shift
    set +e
    "$@" > "$tmp/out.txt" 2>&1
    status=$?
    set -e
    if [ "$status" -ne "$expected" ]; then
        echo "FAILED: $* -> exit $status (expected $expected)"
        cat "$tmp/out.txt"
        failures=$((failures + 1))
        return 1
    fi
    echo "ok: $* -> exit $status"
}

# Step 1: #9A9A9A on #FFFFFF is below AA and must be listed; #6B6B6B passes.
if expect_exit 1 swift scripts/check-contrast.swift scripts/tests/tokens-textSecondary-9A9A9A.json; then
    if ! grep -q "textSecondary #9A9A9A su background #FFFFFF" "$tmp/out.txt"; then
        echo "FAILED: the textSecondary/background pair is not listed"
        failures=$((failures + 1))
    fi
fi
expect_exit 0 swift scripts/check-contrast.swift scripts/tests/tokens-textSecondary-6B6B6B.json || true

# Step 2: two runs of the generator give identical files that type-check.
expect_exit 0 swift scripts/gen-theme.swift scripts/tests/tokens-textSecondary-6B6B6B.json "$tmp/Theme-1.swift" || true
expect_exit 0 swift scripts/gen-theme.swift scripts/tests/tokens-textSecondary-6B6B6B.json "$tmp/Theme-2.swift" || true
if cmp -s "$tmp/Theme-1.swift" "$tmp/Theme-2.swift"; then
    echo "ok: gen-theme is deterministic"
else
    echo "FAILED: gen-theme produces different files"
    failures=$((failures + 1))
fi
expect_exit 0 xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0 "$tmp/Theme-1.swift" || true

# The generator is compiled once (scripts/design/*.swift) for the --verify checks below.
xcrun swiftc -O -o "$tmp/gen-design-scripts" scripts/design/*.swift
gen="$tmp/gen-design-scripts"

# --verify: a real run log passes; drift in a layer id or in a variable id must fail.
# verify-run.log is the output of `figcraft-cli --no-system-fonts run scripts/tests/verify-script.json`;
# without it (it is not part of every checkout) these three checks are skipped.
if [ -f scripts/tests/verify-run.log ]; then
    expect_exit 0 "$gen" --verify scripts/tests/verify-script.json \
        scripts/tests/verify-run.log || true
    sed 's/"result":{"id":2}/"result":{"id":3}/' scripts/tests/verify-run.log > "$tmp/verify-layer.log"
    expect_exit 1 "$gen" --verify scripts/tests/verify-script.json \
        "$tmp/verify-layer.log" || true
    sed 's/"VariableID:1"/"VariableID:9"/' scripts/tests/verify-run.log > "$tmp/verify-variable.log"
    expect_exit 1 "$gen" --verify scripts/tests/verify-script.json \
        "$tmp/verify-variable.log" || true
else
    echo "skipped: --verify checks (scripts/tests/verify-run.log not present)"
fi

# The generator is deterministic and design/scripts matches it.
"$gen" "$tmp/scripts-1" > /dev/null
"$gen" "$tmp/scripts-2" > /dev/null
for script in 01-tokens.json 02-components.json 03-screens.json 04-icon.json; do
    if cmp -s "$tmp/scripts-1/$script" "$tmp/scripts-2/$script" && cmp -s "$tmp/scripts-1/$script" "design/scripts/$script"; then
        echo "ok: $script is deterministic and matches design/scripts"
    else
        echo "FAILED: $script differs between two runs or from design/scripts"
        failures=$((failures + 1))
    fi
done

# F01 on the prototype: at most 6 clicks from the empty library to the running VM.
expect_exit 0 "$gen" --count-clicks design/scripts/03-screens.json || true
cat "$tmp/out.txt"

# visual-diff: identical images → 0 %, exit 0; a 10 % rectangle → exit 1; sizes must match.
xcrun swiftc -O -o "$tmp/visual-diff" scripts/visual-diff.swift
swift scripts/tests/visual-fixtures.swift "$tmp/visual"
vd="$tmp/visual-diff"
v="$tmp/visual"
if expect_exit 0 "$vd" "$v/base.png" "$v/base.png" --tolerance 16 --max-diff 3% --diff "$v/same-diff.png"; then
    if grep -q "^0.00% pixels differ" "$tmp/out.txt" && [ -s "$v/same-diff.png" ]; then
        echo "ok: identical images → 0.00 % and the difference PNG written"
    else
        echo "FAILED: identical images do not give 0.00 % or the difference PNG is missing"
        cat "$tmp/out.txt"
        failures=$((failures + 1))
    fi
fi
if expect_exit 1 "$vd" "$v/base.png" "$v/altered.png" --tolerance 16 --max-diff 3%; then
    if grep -q "^10.00% pixels differ" "$tmp/out.txt"; then
        echo "ok: altered rectangle → 10.00 %"
    else
        echo "FAILED: the altered rectangle does not give 10.00 %"
        cat "$tmp/out.txt"
        failures=$((failures + 1))
    fi
fi
expect_exit 0 "$vd" "$v/base.png" "$v/altered.png" --tolerance 16 --max-diff 10% || true
expect_exit 0 "$vd" "$v/base.png" "$v/faint.png" --tolerance 16 --max-diff 0% || true
expect_exit 1 "$vd" "$v/base.png" "$v/faint.png" --tolerance 4 --max-diff 3% || true
expect_exit 2 "$vd" "$v/base.png" "$v/small.png" || true
expect_exit 0 "$vd" "$v/framed.png" "$v/base.png" --crop 20,20,200,100 --max-diff 0% || true
expect_exit 2 "$vd" "$v/framed.png" "$v/base.png" --crop 100,100,200,100 || true
expect_exit 0 "$vd" "$v/framed.png" "$v/base.png" --crop-at 20,20 --max-diff 0% || true
expect_exit 1 "$vd" "$v/framed.png" "$v/base.png" --crop-at 0,0 --max-diff 3% || true

if [ "$failures" -ne 0 ]; then
    echo "$failures tests failed"
    exit 1
fi
echo "All tests passed."
