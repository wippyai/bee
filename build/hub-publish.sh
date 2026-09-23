#!/bin/sh
# SPDX-License-Identifier: MIT
# Publish Bee to the Wippy Hub: every physical module, then the bee/bee root,
# uploading the sealed packs of one release deployment byte for byte.
#
# Usage: BEE_VERSION=X [BEE_DEPLOYMENT=dist/portable-deployment]
#        [HUB_VISIBILITY=private|public] build/hub-publish.sh check|publish
#   check    dry-runs each upload and compares the Hub digest with the lock hash
#   publish  uploads each immutable protected version, creating missing modules
#
# The deployment is the one `make native-pack BEE_VERSION=X` seals for the
# release executable, so the Hub serves exactly the bytes its lock pins.
set -eu

fail() {
    printf 'hub publish: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail 'usage: build/hub-publish.sh check|publish'
mode=$1
case "$mode" in check | publish) ;; *) fail "unknown mode: $mode" ;; esac

root=$(
    CDPATH=
    export CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
runtime=${WIPPY:-$root/.wippy/bin/bee-wippy}
deployment=${BEE_DEPLOYMENT:-$root/dist/portable-deployment}
case "$runtime" in /*) ;; *) runtime=$root/$runtime ;; esac
case "$deployment" in /*) ;; *) deployment=$root/$deployment ;; esac
[ -x "$runtime" ] || fail "Wippy toolchain is missing: $runtime"
version=${BEE_VERSION:-}
version=${version#v}
[ -n "$version" ] || fail 'Set BEE_VERSION to the release version.'
visibility=${HUB_VISIBILITY:-private}
case "$visibility" in public | private) ;; *) fail "HUB_VISIBILITY must be public or private: $visibility" ;; esac
lock=$deployment/wippy.lock
[ -f "$lock" ] || fail "release deployment is missing: $deployment (build it with make native-pack BEE_VERSION=$version)"

mkdir -p "$root/.wippy"
stage=$(mktemp -d "$root/.wippy/hub-publish.XXXXXXXX")
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT HUP INT TERM

awk '
    $1 == "-" && $2 == "name:" { name = $3; module_version = ""; next }
    name != "" && $1 == "version:" { module_version = $2; next }
    name != "" && $1 == "hash:" { print name, module_version, $2; name = "" }
' "$lock" > "$stage/locked.tsv"

# Each physical module's wippy.yaml carries its Hub identity and metadata;
# bee/bee takes them from the repository root.
printf 'bee/bee %s\n' "$root" > "$stage/modules.tsv"
for manifest in "$root"/modules/*/wippy.yaml; do
    organization=$(awk '$1 == "organization:" { print $2; exit }' "$manifest")
    module=$(awk '$1 == "module:" { print $2; exit }' "$manifest")
    [ -n "$organization" ] && [ -n "$module" ] || fail "module identity is missing: $manifest"
    printf '%s/%s %s\n' "$organization" "$module" "$(dirname -- "$manifest")"
done >> "$stage/modules.tsv"

while read -r module directory; do
    grep -q "^$module " "$stage/locked.tsv" || fail "$module is not in the release deployment lock"
done < "$stage/modules.tsv"
while read -r module module_version hash; do
    grep -q "^$module " "$stage/modules.tsv" || fail "the release deployment locks $module, which is not a Bee module"
    [ "$module_version" = "$version" ] || fail "the release deployment locks $module at $module_version, not $version"
    printf '%s\n' "$hash" | grep -Eq '^sha256:[0-9a-f]{64}$' || fail "the release deployment has no sha256 hash for $module"
done < "$stage/locked.tsv"

# Dependencies publish before their dependents: tsort orders each module after
# the sibling Bee modules its ns.dependency entries name; bee/bee is last.
while read -r module directory; do
    [ "$module" != bee/bee ] || continue
    printf '%s %s\n' "$module" "$module"
    find "$directory/src" -name _index.yaml -exec awk '
        /^[[:space:]]*- / { dependency = 0 }
        /^[[:space:]]*(- )?kind: ns\.dependency[[:space:]]*$/ { dependency = 1 }
        dependency && /^[[:space:]]*(- )?component: bee\// { print $NF }
    ' {} + | sort -u | while read -r dependency; do
        grep -q "^$dependency " "$stage/modules.tsv" || fail "$module depends on $dependency, which is not a physical Bee module"
        printf '%s %s\n' "$dependency" "$module"
    done
done < "$stage/modules.tsv" > "$stage/edges.txt"
tsort "$stage/edges.txt" > "$stage/order.txt"
printf '%s\n' bee/bee >> "$stage/order.txt"

count=0
while read -r module; do
    directory=$(awk -v module="$module" '$1 == module { print $2; exit }' "$stage/modules.tsv")
    hash=$(awk -v module="$module" '$1 == module { print $3; exit }' "$stage/locked.tsv")
    pack=$deployment/.wippy/vendor/bee/${module#bee/}-$version.wapp
    [ -f "$pack" ] || fail "sealed pack is missing: $pack"
    [ "sha256:$(sha256sum "$pack" | awk '{print $1}')" = "$hash" ] || fail "$pack does not match the lock hash $hash"
    if [ "$mode" = check ]; then
        set -- --dry-run
    else
        set -- --create --protected --module-visibility "$visibility"
    fi
    if ! (cd "$root" && TMPDIR=$stage "$runtime" publish --config "$directory" --wapp "$pack" --version "$version" "$@" < /dev/null) > "$stage/publish.log" 2>&1; then
        cat "$stage/publish.log" >&2
        fail "publication of $module $version failed"
    fi
    digest=$(sed -n 's/.*Digest: \(sha256:[0-9a-f]*\).*/\1/p' "$stage/publish.log" | head -n 1)
    printf 'hub publish: %s %s %s lock %s digest %s\n' "$mode" "$module" "$version" "$hash" "${digest:-none}"
    [ "$digest" = "$hash" ] || fail "$module $version: Hub digest ${digest:-none} differs from lock hash $hash"
    count=$((count + 1))
done < "$stage/order.txt"
printf 'hub publish: %s %s modules at %s, every Hub digest equals its lock hash\n' "$mode" "$count" "$version"
