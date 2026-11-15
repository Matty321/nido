#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds Nido Agent (guest/macos/NidoAgent), the helper that runs inside a macOS guest, and assembles
# <out-dir>/NidoAgent.app: signed with the given identity, identifier io.gitlab.pichierri.Nido.Agent,
# Hardened Runtime, no entitlements. TCC permissions in the guest follow this signature.
#
# Usage: scripts/build-agent.sh <identity|-> <out-dir>      (- signs ad hoc)
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: build-agent.sh <identity|-> <out-dir>" >&2
    exit 2
fi
identity="$1"
out="$2"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$repo/guest/macos/NidoAgent"
agent_id="io.gitlab.pichierri.Nido.Agent"

if ! xcrun --find xcstringstool >/dev/null 2>&1; then
    echo "build-agent: xcstringstool is not available (install Xcode 26 or later)" >&2
    exit 1
fi

# A real identity also gets a secure timestamp (needed by notarization; it contacts Apple's server).
timestamp=()
if [[ "$identity" != "-" ]]; then
    timestamp=(--timestamp)
fi

swift build -c release --package-path "$package" --product NidoAgent --arch arm64
binary="$(swift build -c release --package-path "$package" --product NidoAgent --arch arm64 --show-bin-path)/NidoAgent"

app="$out/NidoAgent.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/NidoAgent"
cp "$package/Resources/Info.plist" "$app/Contents/Info.plist"

# The string catalog becomes <lang>.lproj/Localizable.strings.
xcrun xcstringstool compile "$package/Resources/Localizable.xcstrings" --output-directory "$app/Contents/Resources"
if ! compgen -G "$app/Contents/Resources/*.lproj/Localizable.strings" >/dev/null; then
    echo "build-agent: the string catalog produced no Localizable.strings" >&2
    exit 1
fi

# The same for the Info.plist strings (the Screen Recording reason shown by macOS): <lang>.lproj/InfoPlist.strings.
xcrun xcstringstool compile "$package/Resources/InfoPlist.xcstrings" --output-directory "$app/Contents/Resources"
if ! compgen -G "$app/Contents/Resources/*.lproj/InfoPlist.strings" >/dev/null; then
    echo "build-agent: the Info.plist catalog produced no InfoPlist.strings" >&2
    exit 1
fi

codesign --force --sign "$identity" --identifier "$agent_id" --options runtime ${timestamp[@]+"${timestamp[@]}"} "$app"
codesign --verify --strict --deep "$app"

echo "$app"
