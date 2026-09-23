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

# bee/bee is implicit in editable development. The release lock names it as
# the root and selects every physical module at the release version.
{
    printf '%s\n' 'directories:' '  modules: .wippy' '  src: ./src' 'modules:' \
        '  - name: bee/bee' "    version: $version" '    root: true'
    sed -n '/^modules:/,$p' "$root/wippy.lock" | sed '1d' | awk -v version="$version" "$lock_program"
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

cat > "$destination/src/apps/settings/build_info.lua" <<EOF
-- SPDX-License-Identifier: MIT
-- Generated by build/release-source.sh for the release source.
local M = {}
type Info = { version: string, build: string, source: string, source_revision: string, runtime: string, runtime_commit: string, native: string, native_version: string, website: string }
function M.info(): Info
    return {
        version = "$version",
        build = "${revision%%-dirty}",
        source = "https://github.com/wippyai/bee",
        source_revision = "$revision",
        runtime = "$runtime_repository",
        runtime_commit = "$runtime_commit",
        native = "$native_module",
        native_version = "$native_version",
        website = "https://bee.wippy.ai",
    }
end
return M
EOF
touch -r "$root/src/apps/settings/build_info.lua" "$destination/src/apps/settings/build_info.lua"

(cd "$destination" && "$runtime" lint --set lua.type_system.enabled=true --set lua.type_system.strict=true)
