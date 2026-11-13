#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Compares every design render (design/preview/screens/*.png) with the app screenshot of the same
# name in App/build/screens/ and prints a table. With --xcresult <bundle> the screenshots of
# ScreenshotTests are exported from the result bundle first.
#
#   scripts/visual-check.sh [--xcresult App/build/screens.xcresult] [--max-diff 3%]
#
# Normalisation: the renders are 2392×1632 px (window 2200×1440 at 2× plus the drop shadow of the
# design's window: 48 pt left and right, 36 pt above, 60 pt below, from radius 32 and y offset 12);
# the window screenshots are 2200×1440 px without shadow. Each render is cropped to the window,
# --crop 96,72,2200,1440 (measured: the lowest difference against a real-VM screenshot among the
# offsets ±2 px). A render that is already 2200×1440 (S11 full screen) is not cropped.
# The diff PNGs go to App/build/screens/diff/. Exit 1 when a pair is above the threshold or missing.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

renders="design/preview/screens"
screens="App/build/screens"
max_diff="3%"
xcresult=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --xcresult) xcresult="$2"; shift 2 ;;
        --max-diff) max_diff="$2"; shift 2 ;;
        *) echo "visual-check: unknown option $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$screens/diff"
tool="$screens/diff/visual-diff"
xcrun swiftc -O -o "$tool" scripts/visual-diff.swift

if [[ -n "$xcresult" ]]; then
    export_dir="$(mktemp -d -t nido-screens)"
    trap 'rm -rf "$export_dir"' EXIT
    xcrun xcresulttool export attachments --path "$xcresult" --output-path "$export_dir" > /dev/null
    # manifest.json: [{ attachments: [{ exportedFileName, suggestedHumanReadableName }] }]
    /usr/bin/python3 -I - "$export_dir" "$screens" <<'PY'
import json, os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
with open(os.path.join(src, "manifest.json")) as f:
    manifest = json.load(f)
count = 0
for test in manifest:
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "")
        # "S01-Libreria-vuota-Chiaro_0_<uuid>.png" → "S01-Libreria-vuota-Chiaro.png"
        match = re.match(r"^(S\d\d-[A-Za-z0-9-]+-(Chiaro|Scuro)(-dialogo)?)", name)
        if not match:
            continue
        shutil.copyfile(os.path.join(src, item["exportedFileName"]), os.path.join(dst, match.group(1) + ".png"))
        count += 1
print(f"visual-check: {count} screenshots exported to {dst}")
PY
fi

failures=0
printf '%-44s %9s  %s\n' "Screen" "Different" "Result"
for render in "$renders"/S*.png; do
    name="$(basename "$render")"
    app="$screens/$name"
    if [[ ! -f "$app" ]]; then
        printf '%-44s %9s  %s\n' "${name%.png}" "-" "screenshot missing"
        case "$name" in S11-*) ;; *) failures=$((failures + 1)) ;; esac
        continue
    fi
    width="$(sips -g pixelWidth "$render" | awk '/pixelWidth/ {print $2}')"
    crop=()
    if [[ "$width" == "2392" ]]; then crop=(--crop 96,72,2200,1440); fi
    set +e
    out="$("$tool" "$render" "$app" --tolerance 16 --max-diff "$max_diff" ${crop[@]+"${crop[@]}"} \
        --diff "$screens/diff/$name" 2>&1)"
    status=$?
    set -e
    percent="$(printf '%s' "$out" | awk '{print $1; exit}')"
    case "$status" in
        0) verdict="ok" ;;
        1) verdict="above the threshold"; failures=$((failures + 1)) ;;
        *) verdict="error: $out"; percent="-"; failures=$((failures + 1)) ;;
    esac
    printf '%-44s %9s  %s\n' "${name%.png}" "$percent" "$verdict"
done
echo "visual-check: $failures screens above $max_diff or missing (S11 full screen excluded: not captured)"

# The wizard's dialog alone (S02–S06): the native sheet is centred in the window, the design's
# dialog sits 64 pt below the top. The dialog captured by itself is compared with the render cut at
# the design's dialog origin: x = 96 + 2 × 270, y = 72 + 2 × 64 (shadow margin + position at 2×).
# Informative only: it does not change the exit code.
echo
printf '%-44s %9s  %s\n' "Wizard dialog (content only)" "Different" "Result"
for app in "$screens"/S0[2-6]-*-dialogo.png; do
    [[ -f "$app" ]] || continue
    name="$(basename "$app" -dialogo.png)"
    set +e
    out="$("$tool" "$renders/$name.png" "$app" --tolerance 16 --max-diff "$max_diff" --crop-at 636,200 \
        --diff "$screens/diff/$name-dialogo.png" 2>&1)"
    status=$?
    set -e
    percent="$(printf '%s' "$out" | awk '{print $1; exit}')"
    case "$status" in
        0) verdict="ok" ;;
        1) verdict="above the threshold" ;;
        *) verdict="error: $out"; percent="-" ;;
    esac
    printf '%-44s %9s  %s\n' "$name" "$percent" "$verdict"
done
[[ "$failures" -eq 0 ]]
