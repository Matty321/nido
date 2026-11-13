#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Compiles the FigCraft script generator (scripts/design/*.swift) into a temporary binary and runs it.
#
# Usage: scripts/gen-design-scripts.sh <output directory>
#        scripts/gen-design-scripts.sh --verify <script.json> <log of figcraft-cli run>
#        scripts/gen-design-scripts.sh --count-clicks <03-screens.json>   (F01 clicks on the prototype)
#        scripts/gen-design-scripts.sh --list-screens                     (screen frame names)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/nido-gen-design.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -O -o "$work/gen-design-scripts" "$root"/scripts/design/*.swift
"$work/gen-design-scripts" "$@"
