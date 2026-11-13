#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Rebuilds the Nido design from design/scripts: FigCraft file, tokens, Theme.swift, previews,
# app icon PNGs.
#
# Usage: scripts/design-build.sh [--replace]
#   --replace  also copy design/build/nido.figcraft over design/nido.figcraft when they differ.
set -euo pipefail
cd "$(dirname "$0")/.."

FIGCRAFT="$HOME/bin/figcraft-cli"
BUILD="design/build"
PREVIEW="design/preview"
REPLACE=0

for arg in "$@"; do
    case "$arg" in
        --replace) REPLACE=1 ;;
        *) echo "Unknown option: $arg (usage: scripts/design-build.sh [--replace])" >&2; exit 2 ;;
    esac
done

if [ ! -x "$FIGCRAFT" ]; then
    echo "figcraft-cli not found at $FIGCRAFT" >&2
    exit 1
fi

# Built-in fonts only (Inter), so renders match on every machine.
fc() { "$FIGCRAFT" --no-system-fonts "$@"; }

mkdir -p "$BUILD/scripts" "$PREVIEW"

# The generator (scripts/design/*.swift) is compiled once into a temporary binary.
GEN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nido-design-build.XXXXXX")"
trap 'rm -rf "$GEN_DIR"' EXIT
GEN="$GEN_DIR/gen-design-scripts"
xcrun swiftc -O -o "$GEN" scripts/design/*.swift

echo "==> JSON scripts up to date with the generator"
"$GEN" "$BUILD/scripts" > /dev/null
for script in 01-tokens.json 02-components.json 03-screens.json 04-icon.json; do
    if ! cmp -s "$BUILD/scripts/$script" "design/scripts/$script"; then
        echo "design/scripts/$script does not match the generator in scripts/design/:" >&2
        echo "  regenerate it with: scripts/gen-design-scripts.sh design/scripts" >&2
        exit 1
    fi
done

echo "==> FigCraft: tokens, components, screens and prototype, icon"
fc run design/scripts/01-tokens.json --out "$BUILD/01-tokens.figcraft" > "$BUILD/01-tokens.log"
"$GEN" --verify design/scripts/01-tokens.json "$BUILD/01-tokens.log"
fc run design/scripts/02-components.json --in "$BUILD/01-tokens.figcraft" --out "$BUILD/02-components.figcraft" \
    > "$BUILD/02-components.log"
"$GEN" --verify design/scripts/02-components.json "$BUILD/02-components.log"
fc run design/scripts/03-screens.json --in "$BUILD/02-components.figcraft" --out "$BUILD/03-screens.figcraft" \
    > "$BUILD/03-screens.log"
"$GEN" --verify design/scripts/03-screens.json "$BUILD/03-screens.log"
fc run design/scripts/04-icon.json --in "$BUILD/03-screens.figcraft" --out "$BUILD/nido.figcraft" > "$BUILD/04-icon.log"
"$GEN" --verify design/scripts/04-icon.json "$BUILD/04-icon.log"

echo "==> Tokens: design/tokens.json"
fc run design/scripts/90-export-tokens.json --in "$BUILD/nido.figcraft" > "$BUILD/90-export-tokens.log"

# Contrast first: a failing palette must never overwrite the tracked Theme.swift.
echo "==> WCAG AA contrast"
swift scripts/check-contrast.swift design/tokens.json

echo "==> Theme.swift"
swift scripts/gen-theme.swift design/tokens.json App/Nido/Design/Theme.swift

echo "==> Previews in $PREVIEW"
fc render "$BUILD/nido.figcraft" -o "$PREVIEW/Tokens.png" --scale 2 --page Tokens
fc render "$BUILD/nido.figcraft" -o "$PREVIEW/Components.png" --scale 2 --page Components
fc export "$BUILD/nido.figcraft" -o "$PREVIEW/Components-chiaro.png" --scale 2 --page Components \
    --node "Componenti · Chiaro"
fc export "$BUILD/nido.figcraft" -o "$PREVIEW/Components-scuro.png" --scale 2 --page Components \
    --node "Componenti · Scuro"
fc export "$BUILD/nido.figcraft" -o "$PREVIEW/Components-schermate.png" --scale 2 --page Components \
    --node "Componenti delle schermate · Chiaro"
# One PNG per screen frame (scale 2), one overview per mode (scale 1), the prototype page.
rm -rf "$PREVIEW/screens"
mkdir -p "$PREVIEW/screens"
"$GEN" --list-screens | while IFS= read -r frame; do
    file="$(printf '%s' "$frame" | sed 's/ · /-/g; s/ /-/g')"
    fc export "$BUILD/nido.figcraft" -o "$PREVIEW/screens/$file.png" --scale 2 --page Screens --node "$frame" \
        > /dev/null
done
echo "$PREVIEW/screens/ ($(ls "$PREVIEW/screens" | wc -l | tr -d ' ') screens)"
fc export "$BUILD/nido.figcraft" -o "$PREVIEW/overview-chiaro.png" --scale 1 --page Screens --node "Schermate · Chiaro"
fc export "$BUILD/nido.figcraft" -o "$PREVIEW/overview-scuro.png" --scale 1 --page Screens --node "Schermate · Scuro"
fc render "$BUILD/nido.figcraft" -o "$PREVIEW/Prototype.png" --scale 0.5 --page Prototype

echo "==> Icon: App/Nido/Assets.xcassets/AppIcon.appiconset"
ICONSET="App/Nido/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
    scale="$(LC_ALL=C awk "BEGIN { printf \"%.6f\", $size / 1024 }")"
    fc export "$BUILD/nido.figcraft" -o "$ICONSET/AppIcon-$size.png" --scale "$scale" --page Screens --node AppIcon \
        > /dev/null
done
cp "$ICONSET/AppIcon-1024.png" "$PREVIEW/AppIcon-1024.png"
cp "$ICONSET/AppIcon-32.png" "$PREVIEW/AppIcon-32.png"
ls "$ICONSET"

if [ -e design/nido.figcraft ]; then
    if cmp -s "$BUILD/nido.figcraft" design/nido.figcraft; then
        echo "design/nido.figcraft is already up to date."
    elif [ "$REPLACE" -eq 1 ]; then
        cp "$BUILD/nido.figcraft" design/nido.figcraft
        echo "design/nido.figcraft replaced with $BUILD/nido.figcraft."
    else
        echo "design/nido.figcraft exists and differs from $BUILD/nido.figcraft: not overwriting it." >&2
        echo "Check the previews and run again with --replace to replace it." >&2
        exit 3
    fi
fi
echo "Done."
