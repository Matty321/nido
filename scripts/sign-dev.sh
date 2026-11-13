#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build the debug binary and sign it with the virtualization entitlement.
# Ad hoc by default. NIDO_SIGN_IDENTITY (a keychain identity name or SHA-1, e.g. "Apple Development: …")
# signs with that identity instead, with Hardened Runtime.
set -eu
cd "$(dirname "$0")/.."
swift build
identity="${NIDO_SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
    codesign --sign - --entitlements Resources/nido.entitlements --force .build/debug/nido
else
    codesign --sign "$identity" --entitlements Resources/nido.entitlements --options runtime --timestamp=none \
        --force .build/debug/nido
fi

# The CLI looks for gvproxy in libexec/ next to itself. Pinned binary, re-signed with Nido's identifier.
sh scripts/fetch-gvproxy.sh
mkdir -p .build/debug/libexec
cp .build/gvproxy/gvproxy .build/debug/libexec/gvproxy
if [ "$identity" = "-" ]; then
    codesign --sign - --identifier io.gitlab.pichierri.Nido.gvproxy --options runtime --force .build/debug/libexec/gvproxy
else
    codesign --sign "$identity" --identifier io.gitlab.pichierri.Nido.gvproxy --options runtime --timestamp=none \
        --force .build/debug/libexec/gvproxy
fi
