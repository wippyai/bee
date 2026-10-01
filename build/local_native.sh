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

# Retain the proxy version while the exact native worktree content is unchanged.
# Packaging and toolchain validation must select the same module inputs.
stamp=$(date -u +%Y%m%d%H%M%S)
digest=$(find "$directory" -type f ! -path '*/.git/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)
[ -n "$digest" ] || fail 'native content digest is unavailable'
previous=$(python3 - "$out/bee.build.json" "$digest" <<'PYVERSION'
import json
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
if path.exists():
    native = json.loads(path.read_text()).get("native", [])
    versions = {component.get("version") for component in native}
    if len(versions) == 1:
        version = next(iter(versions))
        if isinstance(version, str) and re.fullmatch(r"v0[.]0[.]0-[0-9]{14}-" + sys.argv[2], version):
            print(version)
PYVERSION
)
version=${previous:-v0.0.0-$stamp-$digest}

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
python3 - "$version" "$proxy/$version.info" <<'PYINFO'
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
version = sys.argv[1]
stamp = datetime.strptime(version.split("-")[1], "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)
Path(sys.argv[2]).write_text(json.dumps({"Version": version, "Time": stamp.strftime("%Y-%m-%dT%H:%M:%SZ")}) + "\n")
PYINFO

manifest=$out/bee.build.json
mkdir -p "$out"
python3 "$root/build/local_native_manifest.py" "$root/$input" "$manifest" "$version"
printf '%s\n' "$manifest" > "$out/manifest.path"
printf '%s\n' "$version"
