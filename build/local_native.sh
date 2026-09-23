#!/bin/sh
# SPDX-License-Identifier: MIT
# Serve this worktree's native module to a local development build.
#
# The sealed release build resolves github.com/wippyai/bee/native from the
# module proxy at the version pinned in wippy.build.json. A development build
# must compile the checked-out native sources instead. This script writes the
# worktree into a file-based Go module proxy under a content-derived
# pseudo-version, rewrites the input manifest to require that version, and
# prints the environment that points the pinned builder at the proxy. It never
# edits the module cache, the pinned builder, or the release manifest.
set -eu

fail() {
    printf 'local native: %s\n' "$*" >&2
    exit 1
}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module=github.com/wippyai/bee/native
directory=$root/native
out=$root/.wippy/local-native
input=${1:-wippy.build.json}

[ -f "$directory/go.mod" ] || fail 'native module go.mod is missing'
command -v zip >/dev/null 2>&1 || fail 'zip is required'

# A pseudo-version from the commit time and the exact worktree content: identical
# sources keep a stable version, and any native edit forces a fresh module.
# A fresh pseudo-version per development build. The digest names the exact
# worktree content for diagnostics; the timestamp keeps the version unique so a
# repeated build never collides with a prior cache extraction.
short=$(git -C "$directory" rev-parse --short=12 HEAD 2>/dev/null) || fail 'native sources are not a git checkout'
stamp=$(date -u +%Y%m%d%H%M%S)
digest=$(find "$directory" -type f ! -path '*/.git/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)
[ -n "$digest" ] || fail 'native content digest is unavailable'
version=v0.0.0-$stamp-$digest

proxy=$out/proxy/$module/@v
stage=$(mktemp -d "${TMPDIR:-/tmp}/bee-local-native.XXXXXX")
trap 'rm -rf "$stage"' EXIT
target=$stage/$module@$version
mkdir -p "$target" "$proxy"
cp -a "$directory/." "$target/"
rm -rf "$target/.git" "$target/dist" "$target/.wippy" 2>/dev/null || true
# Fixed timestamps keep identical sources byte-identical, so the archive and its
# module hash are stable across rebuilds of the same worktree content.
find "$target" -exec touch -t 198001010000.00 {} +
# Enumerate files and omit directory entries: Go's dirhash counts a directory
# entry as an empty file, so a recursive archive would fail verification of the
# cached extraction.
(cd "$stage" && find "$module@$version" -type f -print0 | sort -z | xargs -0 zip -qXD "$proxy/$version.zip")
cp "$directory/go.mod" "$proxy/$version.mod"
printf '{"Version":"%s","Time":"%s"}\n' "$version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$proxy/$version.info"

manifest=$out/bee.build.json
mkdir -p "$out"
python3 "$root/build/local_native_manifest.py" "$root/$input" "$manifest" "$version"
printf '%s\n' "$manifest" > "$out/manifest.path"
printf '%s\n' "$version"
