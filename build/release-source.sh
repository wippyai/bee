#!/bin/sh
# SPDX-License-Identifier: MIT
# Stage Bee's release source: every physical module and the bee/bee root at
# one release version. Packing and Hub publication both consume this tree, so
# the versions a portable deployment locks are the versions the Hub receives.
#
# Usage: BEE_VERSION=X [WIPPY=...] [BEE_BUILD_MANIFEST=...] build/release-source.sh DEST
set -eu

fail() {
    printf 'release source: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail 'usage: build/release-source.sh DEST'
destination=$1

root=$(
    CDPATH=
    export CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
runtime=${WIPPY:-$root/.wippy/bin/bee-wippy}
input_manifest=${BEE_BUILD_MANIFEST:-wippy.build.json}
case "$runtime" in /*) ;; *) runtime=$root/$runtime ;; esac
case "$input_manifest" in /*) ;; *) input_manifest=$root/$input_manifest ;; esac
[ -x "$runtime" ] || fail "Wippy toolchain is missing: $runtime"
[ -f "$input_manifest" ] || fail "build manifest is missing: $input_manifest"

version=${BEE_VERSION:-}
version=${version#v}
[ -n "$version" ] || fail 'BEE_VERSION is required'
number='(0|[1-9][0-9]*)'
identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
printf '%s\n' "$version" | grep -Eq "^$number\\.$number\\.$number(-$identifier(\\.$identifier)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$" || fail "invalid BEE_VERSION: $version"

[ ! -e "$destination" ] || [ -z "$(ls -A "$destination")" ] || fail "destination is not empty: $destination"
mkdir -p "$destination"
cp -pR "$root/src" "$destination/src"
cp -pR "$root/modules" "$destination/modules"
mkdir -p "$destination/.wippy"
python3 "$root/build/dependency_artifacts.py" "$root/wippy.lock" "$root/.wippy/vendor" "$destination/.wippy/vendor"
cp -p "$root/wippy.yaml" "$root/.wippy.yaml" "$destination/"

# Rewrites FILE through an awk program with the release version and keeps
# the source timestamp, so a restaged tree differs only in content.
stamp() {
    file=$1
    shift
    awk -v version="$version" "$@" "$file" > "$file.release"
    touch -r "$file" "$file.release"
    mv "$file.release" "$file"
}

# Selects every bee/* row of a lock at the release version.
lock_program='
    $1 == "-" && $2 == "name:" { bee = ($3 ~ /^bee\//) }
    bee && $1 == "version:" { sub(/version:.*/, "version: " version) }
    { print }
'

# The source lock can use either zero- or two-space sequence indentation. The
# staged release lock already contains its own two-space bee/bee row, so shift
# every copied row to the same list indentation while preserving its nesting.
release_lock_program='
    $1 == "-" && $2 == "name:" { source_indent = index($0, "-") - 1; bee = ($3 ~ /^bee\//) }
    bee && $1 == "version:" { sub(/version:.*/, "version: " version) }
    {
        if (NF == 0) { print; next }
        indent = match($0, /[^ ]/) - 1
        sub(/^ */, "")
        indent += 2 - source_indent
        if (indent < 0) indent = 0
        printf "%*s%s\n", indent, "", $0
    }
'

# bee/bee is implicit in editable development. The release lock names it as
# the root and selects every physical module at the release version.
{
    printf '%s\n' 'directories:' '  modules: .wippy' '  src: ./src' 'modules:' \
        '  - name: bee/bee' "    version: $version" '    root: true'
    sed -n '/^modules:/,$p' "$root/wippy.lock" | sed '1d' | awk -v version="$version" "$release_lock_program"
} > "$destination/wippy.lock"
touch -r "$root/wippy.lock" "$destination/wippy.lock"
sed '/^  replacements:/a\    bee/bee: .' "$root/.wippy.yaml" > "$destination/.wippy.yaml"
touch -r "$root/.wippy.yaml" "$destination/.wippy.yaml"

for module in "$destination"/modules/*; do
    stamp "$module/wippy.yaml" '/^version:/ { print "version: " version; next } { print }'
    [ ! -f "$module/wippy.lock" ] || stamp "$module/wippy.lock" "$lock_program"
done

# A published module declares its sibling Bee modules at the release version,
# so the Hub resolves one coherent set. Entries open with "- name:" and a
# dependency's component precedes its version.
dependency_program='
    /^[[:space:]]*- / { dependency = 0; component = "" }
    /^[[:space:]]*(- )?kind: ns\.dependency[[:space:]]*$/ { dependency = 1 }
    dependency && /^[[:space:]]*(- )?component:/ { component = $NF }
    dependency && /^[[:space:]]*(- )?version:/ {
        if (mode == "stamp" && component ~ /^bee\//) sub(/version:.*/, "version: " version)
        if (mode == "list") print component, $NF
        dependency = 0
    }
    mode == "stamp" { print }
'
indexes=$(find "$destination/src" "$destination/modules" -name _index.yaml)
for index in $indexes; do
    stamp "$index" -v mode=stamp "$dependency_program"
done
declared=$(cat $indexes | grep -Ec '^[[:space:]]*(- )?kind: ns\.dependency[[:space:]]*$' || true)
listed=$(awk -v mode=list "$dependency_program" $indexes)
[ "$(printf '%s\n' "$listed" | grep -c .)" = "$declared" ] || fail "a dependency entry has no component/version pair: $declared declared"
unpinned=$(printf '%s\n' "$listed" | awk -v version="$version" '$1 ~ /^bee\// && $2 != version')
[ -z "$unpinned" ] || fail "sibling dependencies outside $version: $unpinned"

revision=$(git -C "$root" rev-parse HEAD 2>/dev/null || printf '%s' unknown)
if [ -n "$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null || true)" ]; then
    revision=$revision-dirty
fi
runtime_repository=$(awk -F'"' '
    /^[[:space:]]*"runtime":[[:space:]]*{/ { runtime = 1; next }
    runtime && /^[[:space:]]*}/ { exit }
    runtime && /"repository":[[:space:]]*"/ { print $4; exit }
' "$input_manifest")
runtime_commit=$(awk -F'"' '
    /^[[:space:]]*"runtime":[[:space:]]*{/ { runtime = 1; next }
    runtime && /^[[:space:]]*}/ { exit }
    runtime && /"commit":[[:space:]]*"/ { print $4; exit }
' "$input_manifest")
native_module=$(awk -F'"' '
    /^[[:space:]]*"native":[[:space:]]*\[/ { native = 1; next }
    native && /^[[:space:]]*]/ { exit }
    native && /"module":[[:space:]]*"/ { print $4; exit }
' "$input_manifest")
native_version=$(awk -F'"' '
    /^[[:space:]]*"native":[[:space:]]*\[/ { native = 1; next }
    native && /^[[:space:]]*]/ { exit }
    native && /"version":[[:space:]]*"/ { print $4; exit }
' "$input_manifest")
[ -n "$runtime_repository" ] || fail "runtime repository is missing: $input_manifest"
[ -n "$runtime_commit" ] || fail "runtime commit is missing: $input_manifest"
[ -n "$native_module" ] || fail "native module is missing: $input_manifest"
[ -n "$native_version" ] || fail "native version is missing: $input_manifest"

cat > "$destination/modules/settings/src/app/build_info.lua" <<EOF
-- SPDX-License-Identifier: MIT
-- Generated by build/release-source.sh for the release source.
local M = {}
type Info = { version: string, build: string, source: string, source_revision: string, runtime: string, runtime_commit: string, native: string, native_version: string, website: string }
function M.info(native: string?, native_version: string?, runtime_commit: string?): Info
    return {
        version = "$version",
        build = "${revision%%-dirty}",
        source = "https://github.com/wippyai/bee",
        source_revision = "$revision",
        runtime = "$runtime_repository",
        runtime_commit = runtime_commit or "$runtime_commit",
        native = native or "$native_module",
        native_version = native_version or "$native_version",
        website = "https://bee.wippy.ai",
    }
end
return M
EOF
touch -r "$root/modules/settings/src/app/build_info.lua" "$destination/modules/settings/src/app/build_info.lua"

# Stamp the Bee root pack with the native/runtime baseline used to build it.
# The executable's host facts remain authoritative after live root-pack updates.
python3 - "$destination/src/env/_index.yaml" "$input_manifest" "$version" "$revision" <<'PY'
import json
from pathlib import Path
import sys

index_path, manifest_path, version, revision = sys.argv[1:]
index = Path(index_path)
text = index.read_text()
start = text.find("- name: binary_identity\n")
end = text.find("- name: workspace_environment\n", start)
if start < 0 or end < 0:
    raise SystemExit("release source: binary_identity entry is missing or out of order")
manifest = json.loads(Path(manifest_path).read_text())
runtime = manifest.get("runtime", {})
native = manifest.get("native", [])
if not runtime.get("repository") or not runtime.get("commit") or not native:
    raise SystemExit("release source: binary runtime/native identity is incomplete")
native_components = []
for item in native:
    if not item.get("package") or not item.get("version"):
        raise SystemExit("release source: native component identity is incomplete")
    native_components.append({"package": item["package"], "version": item["version"]})
first_native = native[0]
identity = {
    "version": version,
    "build": revision.removesuffix("-dirty"),
    "source": "https://github.com/wippyai/bee",
    "source_revision": revision,
    "runtime": runtime["repository"],
    "runtime_commit": runtime["commit"],
    "native": first_native["module"],
    "native_version": first_native["version"],
    "website": "https://bee.wippy.ai",
    "native_components": native_components,
}
def scalar(value):
    return json.dumps(value, ensure_ascii=False)
lines = [
    "- name: binary_identity",
    "  kind: registry.entry",
    "  meta:",
    "    type: bee.binary_identity",
    "    comment: Binary identity and native components selected by this executable; preserved when Bee's live packs change",
    "  data:",
]
for key, value in identity.items():
    if key != "native_components":
        lines.append(f"    {key}: {scalar(value)}")
lines.append("    native_components:")
for item in native_components:
    lines.append(f"    - package: {scalar(item['package'])}")
    lines.append(f"      version: {scalar(item['version'])}")
block = "\n".join(lines) + "\n"
index.write_text(text[:start] + block + text[end:])
PY

(cd "$destination" && "$runtime" lint --set lua.type_system.enabled=true --set lua.type_system.strict=true)
