#!/bin/sh
# SPDX-License-Identifier: MIT
# Pack an independently identified core update; boot bundles retain defaults.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=${WIPPY:-$root/.wippy/bin/bee-wippy}
version=${BEE_CORE_VERSION:?set BEE_CORE_VERSION to a distinct exact release}
version=${version#v}
bundle_version=$(python3 -c 'import json,sys; print(next(p["version"] for p in json.load(open(sys.argv[1]))["application"]["packs"] if p["module"] == "bee/bee"))' "$root/wippy.build.json")
[ "${version%%+*}" != "${bundle_version%%+*}" ] || { echo 'Core updates require a release identity distinct from the boot bundle.' >&2; exit 1; }
mkdir -p "$root/.wippy" "$root/dist"
stage=$(mktemp -d "$root/.wippy/core-pack.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
BEE_VERSION=$version WIPPY=$runtime "$root/build/release-source.sh" "$stage/source"
python3 - "$stage/source/src/deps/_index.yaml" > "$stage/excludes" <<'PY'
import sys
import yaml
document = yaml.safe_load(open(sys.argv[1]))
for entry in document["entries"]:
    if entry["kind"] == "ns.dependency" and entry["component"].startswith("bee/"):
        print(f'{document["namespace"]}:{entry["name"]}')
PY
set -- "$runtime" pack --module bee/bee --silent
while IFS= read -r id; do set -- "$@" --exclude "$id"; done < "$stage/excludes"
output="$root/dist/bee-core-$version.wapp"
(cd "$stage/source" && "$@" "$output")
sha256sum "$output"
