#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds a Nido release on this Mac:
#   scripts/release.sh <version> [--feed-url <url>] [--publish --repo <owner/name>]
#   scripts/release.sh --check <version>
#
# Output in dist/<version>/: Nido-<version>.dmg (Developer ID, notarized, stapled), appcast.xml (signed by
# Sparkle's generate_appcast with the EdDSA key in the login Keychain), Nido-<version>.spdx.json, SHA256SUMS.
#
# Secrets never pass through this script: codesign uses the Keychain identity, notarytool the stored
# profile "nido-notary", generate_appcast reads the EdDSA private key from the Keychain itself.
#
# Environment:
#   NIDO_SPARKLE_BIN           folder with generate_appcast and sign_update (default: the SPM artifacts)
#   NIDO_RELEASE_ALLOW_BRANCH  1 = allow a local release from a branch other than main (never with --publish)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

team_id="ADL6WZ4G2W"
sign_identity="Developer ID Application: Mattia Pichierri ($team_id)"
notary_profile="nido-notary"
bundle_id="io.gitlab.pichierri.Nido"
min_macos="26.0"

say() { echo "release: $*"; }
die() { echo "release: $*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage: scripts/release.sh <version> [--feed-url <url>] [--publish --repo <owner/name>]
       scripts/release.sh --check <version>
EOF
    exit 2
}

# x.y.z -> major*10000 + minor*100 + patch (NidoVersion.build), empty when malformed.
build_number() {
    local v="$1"
    [[ "$v" =~ ^([0-9]+)\.([0-9]{1,2})\.([0-9]{1,2})$ ]] || return 0
    echo $(( 10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]} ))
}

# The CHANGELOG.md section of a version (without its "## [x]" heading), up to the next "## [".
changelog_section() {
    awk -v v="$1" '
        index($0, "## [" v "]") == 1 { found = 1; next }
        found && /^## \[/ { exit }
        found { print }
    ' "$repo_root/CHANGELOG.md"
}

sparkle_bin() {
    local dir="${NIDO_SPARKLE_BIN:-$repo_root/App/build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
    if [[ ! -x "$dir/generate_appcast" || ! -x "$dir/sign_update" ]]; then
        echo "release: Sparkle's tools not found in $dir (set NIDO_SPARKLE_BIN or build the app once)" >&2
        return 1
    fi
    echo "$dir"
}

# Step 1: preliminary checks. Prints every failure, returns non-zero if any.
preflight() {
    local version="$1" publishing="$2"
    local errors=()
    cd "$repo_root"

    local build
    build="$(build_number "$version")"
    [[ -n "$build" ]] || errors+=("invalid version: '$version' (expected x.y.z, minor and patch below 100)")

    if [[ -n "$(git status --porcelain)" ]]; then
        errors+=("git tree not clean (commit or stash the changes before the release)")
    fi
    # The app target syncs every file under App/Nido: an ignored file there (a stray .DS_Store,
    # a local note) would ship in the app although git status shows nothing.
    local ignored
    ignored="$(git status --porcelain --ignored -- App/Nido Resources | sed -n 's/^!! //p' | tr '\n' ' ')"
    if [[ -n "$ignored" ]]; then
        errors+=("files ignored by git would end up in the app: ${ignored% } (remove them before the release)")
    fi
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$branch" != "main" ]]; then
        if [[ "$publishing" == 1 || "${NIDO_RELEASE_ALLOW_BRANCH:-}" != 1 ]]; then
            errors+=("branch '$branch', not main (for a local trial: NIDO_RELEASE_ALLOW_BRANCH=1, never with --publish)")
        else
            echo "release: warning: branch '$branch', not main (NIDO_RELEASE_ALLOW_BRANCH=1)" >&2
        fi
    fi

    local current
    current="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/NidoCore/Model/NidoVersion.swift)"
    [[ "$current" == "$version" ]] || errors+=("version differs from NidoVersion.current: '$version' versus '$current'")

    local pbx="App/Nido.xcodeproj/project.pbxproj" marketing builds
    marketing="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$pbx" | sort -u | tr '\n' ' ')"
    [[ "$marketing" == "$version " ]] || errors+=("MARKETING_VERSION in the project: '${marketing% }' (expected '$version' in every configuration)")
    builds="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$pbx" | sort -u | tr '\n' ' ')"
    [[ -z "$build" || "$builds" == "$build " ]] || errors+=("CURRENT_PROJECT_VERSION in the project: '${builds% }' (expected '$build' in every configuration)")

    local first_section
    first_section="$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' CHANGELOG.md | head -n 1)"
    if ! grep -qF "## [$version]" CHANGELOG.md; then
        errors+=("section '## [$version]' missing from CHANGELOG.md")
    elif [[ "$first_section" != "$version" ]]; then
        errors+=("the first section of CHANGELOG.md is '$first_section', not '$version'")
    elif [[ -z "$(changelog_section "$version" | tr -d '[:space:]')" ]]; then
        errors+=("section '## [$version]' of CHANGELOG.md is empty")
    fi
    # The app's English notes are the repository's CHANGELOG.md (the other languages are translations).
    cmp -s CHANGELOG.md App/Nido/ReleaseNotes/en.lproj/CHANGELOG.md ||
        errors+=("App/Nido/ReleaseNotes/en.lproj/CHANGELOG.md is not a copy of CHANGELOG.md")

    # Output captured first: "cmd | grep -q" fails under pipefail when grep exits early (SIGPIPE).
    local identities
    identities="$(security find-identity -v -p codesigning)"
    if [[ "$identities" != *"\"$sign_identity\""* ]]; then
        errors+=("identity '$sign_identity' missing or not valid in the Keychain")
    fi
    # A read-only call that needs working credentials; its output (submission ids) is not shown.
    if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
        errors+=("notarytool profile '$notary_profile' not usable (xcrun notarytool store-credentials $notary_profile)")
    fi
    sparkle_bin >/dev/null || errors+=("Sparkle's tools missing")

    if (( ${#errors[@]} )); then
        local e
        for e in "${errors[@]}"; do echo "release: error: $e" >&2; done
        return 1
    fi
    say "preliminary checks ok for $version (build $build)"
}

# Minimal Markdown to HTML for the changelog style: ### headings, "- " lists, paragraphs, **bold**, `code`.
# No DOCTYPE/body, so generate_appcast embeds it in the item's description (and signs it with the feed).
notes_html() {
    /usr/bin/python3 -c '
import html, re, sys
out, in_list = [], False
def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
for line in sys.stdin.read().splitlines():
    if line.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>" + inline(line[2:]) + "</li>"); continue
    if in_list: out.append("</ul>"); in_list = False
    if line.startswith("### "): out.append("<h3>" + inline(line[4:]) + "</h3>")
    elif line.strip(): out.append("<p>" + inline(line) + "</p>")
if in_list: out.append("</ul>")
print("\n".join(out))
'
}

info_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

# Step 2 checks on a built or mounted app: Developer ID of the team, strict deep verification, identifiers.
verify_app() {
    local app="$1" version="$2" build="$3"
    codesign --verify --deep --strict "$app" || die "codesign --verify --deep --strict failed on $app"
    local info
    info="$(codesign -dv "$app" 2>&1)"
    [[ "$info" == *"TeamIdentifier=$team_id"* ]] || die "$app is not signed by team $team_id"
    [[ "$info" == *"Identifier=$bundle_id"* ]] || die "$app: unexpected identifier"
    [[ "$(codesign -dvv "$app" 2>&1)" == *"Authority=$sign_identity"* ]] || die "$app is not signed with '$sign_identity'"
    [[ "$(grep -E '^CodeDirectory' <<<"$info")" == *runtime* ]] || die "$app: Hardened Runtime missing"
    local helper id
    for helper in gvproxy:"$bundle_id.gvproxy" nido:"$bundle_id.cli"; do
        id="${helper#*:}"
        info="$(codesign -dv "$app/Contents/Helpers/${helper%%:*}" 2>&1)"
        [[ "$info" == *"Identifier=$id"* && "$info" == *"TeamIdentifier=$team_id"* ]] ||
            die "$app: Contents/Helpers/${helper%%:*} not signed as $id by team $team_id"
    done
    info="$(codesign -dv "$app/Contents/Frameworks/Sparkle.framework" 2>&1)"
    [[ "$info" == *"TeamIdentifier=$team_id"* ]] || die "$app: Sparkle not signed by team $team_id"
    [[ "$(info_value "$app" CFBundleShortVersionString)" == "$version" ]] || die "$app: CFBundleShortVersionString differs from $version"
    [[ "$(info_value "$app" CFBundleVersion)" == "$build" ]] || die "$app: CFBundleVersion differs from $build"
    [[ "$(info_value "$app" LSMinimumSystemVersion)" == "$min_macos" ]] || die "$app: LSMinimumSystemVersion differs from $min_macos"
}

# Step 8, publication: prints the commands, runs them only after "y" typed on the terminal.
# Reads the answer from /dev/tty, never from a pipe; without a terminal nothing is published.
publish() {
    local version="$1" repo="$2" out="$3" notes_md="$4" built_sha="$5"
    local tag="v$version"
    # The tag names the commit that was checked and built, never whatever HEAD is now: the build
    # and the notarization take minutes, and the tree must still be that commit, clean.
    cd "$repo_root"
    if [[ "$(git rev-parse HEAD)" != "$built_sha" || -n "$(git status --porcelain)" ]]; then
        die "the repository changed during the build (expected $built_sha, clean): not publishing"
    fi
    local assets=("$out/Nido-$version.dmg" "$out/appcast.xml" "$out/Nido-$version.spdx.json" "$out/SHA256SUMS")
    local commands=(
        "git -C $(printf %q "$repo_root") tag -a $tag -m $(printf %q "Nido $version") $built_sha"
        "git -C $(printf %q "$repo_root") push https://github.com/$repo.git refs/tags/$tag"
        "gh release create $tag --repo $repo --draft --verify-tag --title $(printf %q "Nido $version") --notes-file $(printf %q "$notes_md") $(printf '%q ' "${assets[@]}")"
        "gh release edit $tag --repo $repo --draft=false --latest"
    )
    echo
    say "publishing to $repo: commands"
    local c
    for c in "${commands[@]}"; do echo "  $c"; done
    local answer=""
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        say "no terminal for the confirmation: not publishing"
        return 0
    fi
    printf 'Publish Nido %s to %s? [y/N] ' "$version" "$repo" >/dev/tty
    read -r answer <&3 || answer=""
    exec 3<&-
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        say "publishing cancelled: no command run"
        return 0
    fi
    for c in "${commands[@]}"; do
        say "running: $c"
        eval "$c" || die "command failed: $c"
    done
    say "Nido $version published at https://github.com/$repo/releases/tag/$tag"
}

main() {
    local version="" feed_url="" repo="" publishing=0 check_only=0
    while (( $# )); do
        case "$1" in
            --check) check_only=1; version="${2:-}"; shift 2 || usage ;;
            --feed-url) feed_url="${2:-}"; shift 2 || usage ;;
            --repo) repo="${2:-}"; shift 2 || usage ;;
            --publish) publishing=1; shift ;;
            -h|--help) usage ;;
            -*) usage ;;
            *) [[ -z "$version" ]] || usage; version="$1"; shift ;;
        esac
    done
    [[ -n "$version" ]] || usage

    if (( check_only )); then
        preflight "$version" 0
        return
    fi

    # Publishing needs an existing GitHub repo: stop here, before building and before asking anything.
    if (( publishing )); then
        # A private working copy (marked by .nido-private) has a history that must never reach GitHub:
        # the tag push below would upload it. Publish only from the public repository.
        [[ ! -e "$repo_root/.nido-private" ]] || die "this is a private working copy: publish from the public repository"
        [[ -n "$repo" ]] || die "--publish needs --repo <owner/name>"
        [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repo: '$repo'"
        gh repo view "$repo" --json name >/dev/null 2>&1 || die "gh repo view cannot find '$repo' (no such repo, or gh not signed in)"
        [[ -n "$feed_url" ]] || die "--publish needs --feed-url: without it, the published app would never find updates"
    fi
    # Plain http only for a feed served on this Mac's loopback (local update test), never when publishing.
    if [[ -n "$feed_url" && "$feed_url" != https://* ]]; then
        if (( publishing )) || ! [[ "$feed_url" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?/ ]]; then
            die "--feed-url must be an https address (http only on 127.0.0.1/localhost for local trials)"
        fi
        say "WARNING: local http feed ($feed_url), only for trials on this Mac"
    fi

    preflight "$version" "$publishing"
    # The commit the preflight checked: the build is made from it and the tag will name it.
    local built_sha
    built_sha="$(git -C "$repo_root" rev-parse HEAD)"
    local build sparkle
    build="$(build_number "$version")"
    sparkle="$(sparkle_bin)"
    cd "$repo_root"

    local out="$repo_root/dist/$version"
    if [[ -e "$out" ]]; then
        say "removing the previous local release in dist/$version"
        rm -rf "$out"
    fi
    mkdir -p "$out"
    local work
    work="$(mktemp -d -t nido-release)"
    local mount="$work/mount"
    trap 'hdiutil detach -quiet "'"$mount"'" 2>/dev/null || true; rm -rf "'"$work"'"' EXIT

    # Step 2: tests, signed Release build, checks.
    say "swift test"
    swift test
    say "signed Release build ($sign_identity), feed '${feed_url:-none}'"
    NIDO_SIGN_IDENTITY="$sign_identity" NIDO_FEED_URL="$feed_url" bash scripts/build-app.sh
    local app="App/build/Build/Products/Release/Nido.app"
    verify_app "$app" "$version" "$build"
    [[ "$(info_value "$app" SUFeedURL)" == "$feed_url" ]] || die "$app: SUFeedURL differs from '$feed_url'"
    say "app verified: team $team_id, CFBundleVersion $build, minimum macOS $min_macos"

    # Step 3: DMG with the app and a link to /Applications, signed with the Developer ID.
    local dmg="$out/Nido-$version.dmg"
    mkdir -p "$work/dmg"
    ditto "$app" "$work/dmg/Nido.app"
    ln -s /Applications "$work/dmg/Applications"
    hdiutil create -quiet -volname "Nido $version" -srcfolder "$work/dmg" -fs APFS -format UDZO -ov "$dmg"
    codesign --sign "$sign_identity" --timestamp "$dmg"
    codesign --verify --strict "$dmg"
    [[ "$(codesign -dv "$dmg" 2>&1)" == *"TeamIdentifier=$team_id"* ]] || die "DMG not signed by team $team_id"

    # Step 4: notarization (uploads the DMG to Apple), then staple.
    say "notarization (uploading to Apple, waiting for the result)"
    local started result submission status elapsed
    started=$(date +%s)
    result="$(xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait --output-format json)" || true
    elapsed=$(( $(date +%s) - started ))
    submission="$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("id",""))' <<<"$result" 2>/dev/null || true)"
    status="$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("status",""))' <<<"$result" 2>/dev/null || true)"
    say "notarization: id ${submission:-?}, status ${status:-?}, ${elapsed}s"
    if [[ "$status" != "Accepted" ]]; then
        if [[ -n "$submission" ]]; then
            xcrun notarytool log "$submission" --keychain-profile "$notary_profile" >&2 || true
        else
            echo "$result" >&2
        fi
        die "notarization not accepted"
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"

    # Step 5: Gatekeeper on the DMG and on the app inside it.
    spctl -a -t open --context context:primary-signature -vv "$dmg"
    mkdir -p "$mount"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
    spctl -a -vv "$mount/Nido.app"
    verify_app "$mount/Nido.app" "$version" "$build"
    [[ "$(readlink "$mount/Applications")" == /Applications ]] || die "DMG: link to Applications missing"
    hdiutil detach -quiet "$mount"

    # Step 6: appcast by generate_appcast, which signs the update (sparkle:edSignature) and the feed with the
    # EdDSA key in the Keychain (the app requires a signed feed). No edits afterwards: they would break it.
    local notes_md="$work/Nido-$version.md" stage="$work/appcast"
    changelog_section "$version" | sed -e '/./,$!d' > "$notes_md"
    mkdir -p "$stage"
    cp "$dmg" "$stage/"
    notes_html < "$notes_md" > "$stage/Nido-$version.html"
    local appcast_args=(--embed-release-notes --maximum-deltas 0)
    if [[ -n "$repo" ]]; then
        appcast_args+=(--download-url-prefix "https://github.com/$repo/releases/download/v$version/")
    elif [[ -n "$feed_url" ]]; then
        appcast_args+=(--download-url-prefix "${feed_url%/*}/")
    fi
    say "appcast (generate_appcast; macOS may ask for access to the EdDSA key in the Keychain)"
    "$sparkle/generate_appcast" "${appcast_args[@]}" -o "$stage/appcast.xml" "$stage"
    cp "$stage/appcast.xml" "$out/appcast.xml"
    local feed="$out/appcast.xml" size
    size="$(stat -f %z "$dmg")"
    grep -q "<sparkle:version>$build</sparkle:version>" "$feed" || die "appcast: sparkle:version differs from $build"
    grep -q "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$feed" || die "appcast: shortVersionString differs from $version"
    grep -q "<sparkle:minimumSystemVersion>$min_macos</sparkle:minimumSystemVersion>" "$feed" || die "appcast: minimumSystemVersion differs from $min_macos"
    grep -q "length=\"$size\"" "$feed" || die "appcast: length differs from $size"
    grep -q 'sparkle:edSignature="' "$feed" || die "appcast: sparkle:edSignature missing"
    grep -q 'sparkle-signatures:' "$feed" || die "appcast: feed signature missing"
    local ed_signature
    ed_signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$feed" | head -n 1)"
    "$sparkle/sign_update" --verify "$dmg" "$ed_signature" || die "appcast: the DMG's EdDSA signature is not valid"
    "$sparkle/sign_update" --verify "$feed" || die "appcast: the feed signature is not valid"

    # Step 7: SBOM and checksums.
    swift scripts/gen-sbom.swift --version "$version" --out "$out/Nido-$version.spdx.json"
    (cd "$out" && shasum -a 256 "Nido-$version.dmg" "Nido-$version.spdx.json" appcast.xml > SHA256SUMS && shasum -a 256 -c SHA256SUMS >/dev/null)

    say "release $version ready in dist/$version (notarization ${elapsed}s, id $submission):"
    ls -l "$out"

    if (( publishing )); then
        publish "$version" "$repo" "$out" "$notes_md" "$built_sha"
    fi
}

# Sourcing the script (for a dry test of publish) defines the functions without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
