#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds Nido.app in Debug and in Release into App/build and checks both signatures: the only
# entitlement must be com.apple.security.virtualization and the Hardened Runtime flag must be set.
# (The DEBUG-only launch arguments are ignored in Release by AppEnvironment, see its unit tests.)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# The project sets ENABLE_HARDENED_RUNTIME = YES, but Xcode drops it for ad-hoc signatures
# ("Disabling hardened runtime with ad-hoc codesigning"), so the M2 build asks codesign for it
# explicitly (and again for the final seal below).
# ARCHS=arm64 covers the local package targets too: Release would otherwise build NidoCore for
# x86_64, where the Virtualization save/restore and Rosetta APIs do not exist. Hosted unit tests are built
# without it: library validation rejects an injected bundle without a Team ID.
entitlements="$(mktemp -t nido-entitlements)"
trap 'rm -f "$entitlements"' EXIT

# NIDO_SIGN_IDENTITY (a keychain identity name or SHA-1, e.g. "Apple Development: …") signs with that
# identity instead of ad hoc. The checks below stay the same: one entitlement, Hardened Runtime.
signing=()
if [[ -n "${NIDO_SIGN_IDENTITY:-}" && "$NIDO_SIGN_IDENTITY" != "-" ]]; then
    signing=(CODE_SIGN_IDENTITY="$NIDO_SIGN_IDENTITY")
    # The package's resource bundle (Nido_NidoCore) has no signing settings of its own: Xcode signs it
    # automatically and without a team, which a named identity rejects. Sign every target manually, with
    # the identity's Team ID. The project itself signs ad hoc and names no team.
    signing+=(CODE_SIGN_STYLE=Manual)
    # The Team ID is the certificate's organizational unit: an "Apple Development: Name (ID)" identity
    # ends with a personal ID, not the team. A SHA-1 identity is looked up for its name first. The ID in
    # the name's trailing parentheses is the fallback ("Developer ID Application: Name (TEAMID)").
    identity_name="$NIDO_SIGN_IDENTITY"
    if [[ "$identity_name" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        identity_name="$(security find-identity -v -p codesigning |
            sed -n "s/.*$identity_name \"\(.*\)\"\$/\1/Ip" | head -n 1)" || identity_name=""
    fi
    team=""
    if [[ -n "$identity_name" ]]; then
        team="$(security find-certificate -c "$identity_name" -p 2>/dev/null |
            /usr/bin/openssl x509 -noout -subject -nameopt sep_multiline,sname 2>/dev/null |
            sed -n 's/^ *OU=//p' | head -n 1)" || team=""
    fi
    # An OU that is not a Team ID (a name, say) is no team: clear it so the fallback below runs.
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || team=""
    if [[ -z "$team" && "$identity_name" =~ \(([A-Z0-9]{10})\)$ ]]; then
        team="${BASH_REMATCH[1]}"
    fi
    if [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
        signing+=(DEVELOPMENT_TEAM="$team")
    fi
fi
# NIDO_FEED_URL (the appcast address, set by release.sh) becomes the build setting behind SUFeedURL;
# unset or empty keeps the project's empty default (no update feed).
if [[ -n "${NIDO_FEED_URL:-}" ]]; then
    signing+=(NIDO_FEED_URL="$NIDO_FEED_URL")
fi

gvproxy_id="io.gitlab.pichierri.Nido.gvproxy"
cli_id="io.gitlab.pichierri.Nido.cli"
sign_identity="-"
# A real identity also gets a secure timestamp (needed by notarization; it contacts Apple's server).
timestamp=()
if [[ -n "${NIDO_SIGN_IDENTITY:-}" && "$NIDO_SIGN_IDENTITY" != "-" ]]; then
    sign_identity="$NIDO_SIGN_IDENTITY"
    timestamp=(--timestamp)
fi

# The pinned gvproxy is downloaded and checked by fetch-gvproxy.sh, never at run time.
sh scripts/fetch-gvproxy.sh

# The command-line tool ships inside the app (Contents/Helpers/nido); ~/.local/bin/nido links to it.
swift build -c release --product nido --arch arm64
cli_binary="$(swift build -c release --product nido --arch arm64 --show-bin-path)/nido"

check() {
    local configuration="$1"
    local app="App/build/Build/Products/$configuration/Nido.app"

    xcodebuild -project App/Nido.xcodeproj -scheme Nido -configuration "$configuration" \
        -derivedDataPath App/build build ARCHS=arm64 OTHER_CODE_SIGN_FLAGS=--options=runtime ${signing[@]+"${signing[@]}"}

    if [[ ! -d "$app" ]]; then
        echo "build-app: $app not found" >&2
        exit 1
    fi

    # Sparkle first (innermost code): the app is not sandboxed, so its XPC services are not needed; drop them
    # (and the dangling top-level link) before signing. Then Autoupdate, Updater.app and the framework, all with
    # Hardened Runtime and no entitlements, keeping the identifiers Sparkle ships with.
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"
    if [[ ! -d "$sparkle" ]]; then
        echo "build-app: $configuration: $sparkle is missing" >&2
        exit 1
    fi
    rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
    local sparkle_code
    for sparkle_code in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        codesign --force --sign "$sign_identity" --options runtime ${timestamp[@]+"${timestamp[@]}"} "$sparkle_code"
    done

    # Helper: copy the pinned gvproxy into the app, sign it with Nido's identifier and Hardened Runtime and
    # no entitlements, then seal the app again keeping its own entitlements.
    mkdir -p "$app/Contents/Helpers"
    cp .build/gvproxy/gvproxy "$app/Contents/Helpers/gvproxy"
    # Check the copy against the pin again, right before signing it: nothing may have replaced the
    # file between fetch-gvproxy.sh and here (the Swift and Xcode builds ran in between).
    local pinned copied
    pinned="$(/usr/bin/plutil -extract sha256 raw -o - Resources/gvproxy/release.json)"
    copied="$(/usr/bin/shasum -a 256 "$app/Contents/Helpers/gvproxy" | /usr/bin/awk '{print $1}')"
    if [[ "$copied" != "$pinned" ]]; then
        echo "build-app: $configuration: the copied gvproxy does not match the pin (sha256 $copied, expected $pinned)" >&2
        exit 1
    fi
    codesign --force --sign "$sign_identity" --identifier "$gvproxy_id" --options runtime ${timestamp[@]+"${timestamp[@]}"} \
        "$app/Contents/Helpers/gvproxy"
    # The CLI is signed after gvproxy and before the app seal (inside out), with the virtualization entitlement only.
    cp "$cli_binary" "$app/Contents/Helpers/nido"
    codesign --force --sign "$sign_identity" --identifier "$cli_id" --entitlements Resources/nido.entitlements \
        --options runtime ${timestamp[@]+"${timestamp[@]}"} "$app/Contents/Helpers/nido"
    codesign --force --sign "$sign_identity" --options runtime ${timestamp[@]+"${timestamp[@]}"} \
        --preserve-metadata=entitlements,identifier "$app"

    # Entitlements: exactly one key, the virtualization one, set to true.
    codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
    local keys
    keys="$(plutil -convert json -o - "$entitlements" | /usr/bin/python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(k + "=" + json.dumps(v) for k, v in d.items())))')"
    local expected='com.apple.security.virtualization=true'
    if [[ "$keys" != "$expected" ]]; then
        echo "build-app: $configuration: unexpected entitlements: '$keys' (expected '$expected')" >&2
        exit 1
    fi

    # Hardened Runtime: codesign -dv prints e.g. "CodeDirectory v=20500 size=... flags=0x10002(adhoc,runtime)".
    local flags
    flags="$(codesign -dv "$app" 2>&1 | grep -E '^CodeDirectory' || true)"
    if [[ "$flags" != *runtime* ]]; then
        echo "build-app: $configuration: Hardened Runtime missing: '$flags'" >&2
        exit 1
    fi

    # The helper: present, signed with Nido's identifier, Hardened Runtime, no entitlements.
    local helper="$app/Contents/Helpers/gvproxy"
    if [[ ! -f "$helper" ]]; then
        echo "build-app: $configuration: $helper is missing" >&2
        exit 1
    fi
    codesign --verify --strict "$helper"
    local helper_info
    helper_info="$(codesign -dv "$helper" 2>&1)"
    if [[ "$helper_info" != *"Identifier=$gvproxy_id"* ]]; then
        echo "build-app: $configuration: unexpected gvproxy identifier: '$helper_info'" >&2
        exit 1
    fi
    if ! grep -E '^CodeDirectory' <<<"$helper_info" | grep -q runtime; then
        echo "build-app: $configuration: Hardened Runtime missing on gvproxy" >&2
        exit 1
    fi
    if [[ -n "$(codesign -d --entitlements - --xml "$helper" 2>/dev/null)" ]]; then
        echo "build-app: $configuration: gvproxy has entitlements" >&2
        exit 1
    fi

    # The CLI: present, Nido's identifier, Hardened Runtime, exactly the virtualization entitlement.
    local cli="$app/Contents/Helpers/nido"
    if [[ ! -f "$cli" ]]; then
        echo "build-app: $configuration: $cli is missing" >&2
        exit 1
    fi
    codesign --verify --strict "$cli"
    local cli_info
    cli_info="$(codesign -dv "$cli" 2>&1)"
    if [[ "$cli_info" != *"Identifier=$cli_id"* ]]; then
        echo "build-app: $configuration: unexpected identifier for the nido command: '$cli_info'" >&2
        exit 1
    fi
    if ! grep -E '^CodeDirectory' <<<"$cli_info" | grep -q runtime; then
        echo "build-app: $configuration: Hardened Runtime missing on the nido command" >&2
        exit 1
    fi
    codesign -d --entitlements - --xml "$cli" > "$entitlements" 2>/dev/null
    local cli_keys
    cli_keys="$(plutil -convert json -o - "$entitlements" | /usr/bin/python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(k + "=" + json.dumps(v) for k, v in d.items())))')"
    if [[ "$cli_keys" != "$expected" ]]; then
        echo "build-app: $configuration: unexpected entitlements for the nido command: '$cli_keys' (expected '$expected')" >&2
        exit 1
    fi

    # Every code in Frameworks and Helpers: Hardened Runtime. Sparkle: no entitlements at all, no XPC services.
    local code
    while IFS= read -r code; do
        if ! codesign -dv "$code" 2>&1 | grep -E '^CodeDirectory' | grep -q runtime; then
            echo "build-app: $configuration: Hardened Runtime missing on ${code#"$app"/}" >&2
            exit 1
        fi
    done < <(find "$app/Contents/Frameworks" "$app/Contents/Helpers" \( -name '*.framework' -o -name '*.app' -o -name Autoupdate -o -type f -perm -u+x \) -not -path '*/Versions/Current/*' -not -path '*/Headers/*' 2>/dev/null | sort -u)
    for code in "$sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"; do
        codesign --verify --strict "$code"
        if [[ -n "$(codesign -d --entitlements - --xml "$code" 2>/dev/null)" ]]; then
            echo "build-app: $configuration: ${code#"$app"/} has entitlements" >&2
            exit 1
        fi
    done
    if [[ -e "$sparkle/Versions/B/XPCServices" ]]; then
        echo "build-app: $configuration: Sparkle's XPCServices still present" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$app"

    echo "build-app: OK – $app"
    echo "  Sparkle: Hardened Runtime, no entitlements, no XPCServices"
    echo "  helper: gvproxy ($gvproxy_id), Hardened Runtime, no entitlements"
    echo "  helper: nido ($cli_id), Hardened Runtime, entitlements $cli_keys"
    echo "  entitlements: $keys"
    echo "  $flags"
}

check Debug
check Release
