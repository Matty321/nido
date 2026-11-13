#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds Nido in Release and installs it on this Mac, replacing the previous version:
#   /Applications/Nido.app   the app, with the command and gvproxy inside (Contents/Helpers),
#                            all signed by build-app.sh: Developer ID if the Mac has one, else ad hoc
#   ~/.local/bin/nido        a symlink to /Applications/Nido.app/Contents/Helpers/nido
# Refuses while the app runs: replacing it would stop its VMs.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

app_dest="/Applications/Nido.app"
cli_link="$HOME/.local/bin/nido"
cli_target="$app_dest/Contents/Helpers/nido"
legacy_gvproxy="$HOME/.local/libexec/nido/gvproxy"

if pgrep -x Nido >/dev/null; then
    echo "install: Nido is open. Quit it (its VMs stop) and try again." >&2
    exit 1
fi

# The CLI and gvproxy must carry the same Team ID (the CLI accepts only a gvproxy signed like itself),
# so one identity signs everything: the Developer ID when installed, else ad hoc.
if [[ -z "${NIDO_SIGN_IDENTITY:-}" ]]; then
    identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
    export NIDO_SIGN_IDENTITY="${identity:--}"
fi
echo "install: signing with ${NIDO_SIGN_IDENTITY/#-/ad hoc}"

bash scripts/build-app.sh

rm -rf "$app_dest"
ditto App/build/Build/Products/Release/Nido.app "$app_dest"
codesign --verify --deep --strict "$app_dest"
codesign --verify --strict "$cli_target"

mkdir -p "$HOME/.local/bin"
if [[ -e "$cli_link" || -L "$cli_link" ]]; then
    # Replace an old copy or a link of ours; never someone else's link.
    if [[ -L "$cli_link" && "$(readlink "$cli_link")" != "$cli_target" ]]; then
        echo "install: $cli_link links to another program: leaving it alone." >&2
        exit 1
    fi
    rm -f "$cli_link"
fi
ln -s "$cli_target" "$cli_link"

# The per-user gvproxy copy of the old layout: the CLI now finds the one inside the app.
rm -f "$legacy_gvproxy"
rmdir "$(dirname "$legacy_gvproxy")" 2>/dev/null || true

echo "install: Nido $(defaults read "$app_dest/Contents/Info.plist" CFBundleShortVersionString) in $app_dest"
echo "install: nido $("$cli_link" --version) in $cli_link -> $(readlink "$cli_link")"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "install: add $HOME/.local/bin to your PATH to use 'nido' from Terminal." ;;
esac
