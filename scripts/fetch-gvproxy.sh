#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Download the pinned gvproxy binary (Resources/gvproxy/release.json) into .build/gvproxy/gvproxy.
# Downloads only when the file is missing; always verifies size and SHA-256 against the pin.
# A mismatch deletes the file and exits with an error. HTTPS only, redirects included.
set -eu
cd "$(dirname "$0")/.."

release=Resources/gvproxy/release.json
dest_dir=.build/gvproxy
dest="$dest_dir/gvproxy"

field() {
    /usr/bin/plutil -extract "$1" raw -o - "$release"
}

url=$(field url)
size=$(field size)
sha256=$(field sha256)
version=$(field version)

case "$url" in
    https://*) ;;
    *) echo "fetch-gvproxy: the URL in $release is not https: $url" >&2; exit 1 ;;
esac

verify() {
    actual_size=$(/usr/bin/stat -f %z "$1")
    if [ "$actual_size" != "$size" ]; then
        echo "fetch-gvproxy: size mismatch ($actual_size, expected $size)" >&2
        return 1
    fi
    actual_sha=$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')
    if [ "$actual_sha" != "$sha256" ]; then
        echo "fetch-gvproxy: SHA-256 mismatch ($actual_sha, expected $sha256)" >&2
        return 1
    fi
}

mkdir -p "$dest_dir"
if [ -f "$dest" ]; then
    echo "fetch-gvproxy: gvproxy $version already present, verifying"
else
    echo "fetch-gvproxy: downloading gvproxy $version"
    tmp="$dest.download"
    rm -f "$tmp"
    if ! /usr/bin/curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --output "$tmp" "$url"; then
        rm -f "$tmp"
        echo "fetch-gvproxy: download failed" >&2
        exit 1
    fi
    # Verify the temporary file before it takes its final name: nothing unchecked ever sits at $dest.
    if ! verify "$tmp"; then
        rm -f "$tmp"
        echo "fetch-gvproxy: downloaded file discarded" >&2
        exit 1
    fi
    chmod 0755 "$tmp"
    mv "$tmp" "$dest"
fi

if ! verify "$dest"; then
    rm -f "$dest"
    echo "fetch-gvproxy: $dest deleted" >&2
    exit 1
fi
chmod 0755 "$dest"
echo "fetch-gvproxy: $dest verified (sha256 $sha256)"
