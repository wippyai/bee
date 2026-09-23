#!/bin/sh
# SPDX-License-Identifier: MIT
# Publish Bee to the Wippy Hub: every physical module, then the bee/bee root,
# all at BEE_VERSION from one release source (build/release-source.sh).
#
# Usage: BEE_VERSION=X [HUB_VISIBILITY=private|public] build/hub-publish.sh check|publish
#   check    packs every module through the Hub publisher with --dry-run
#   publish  uploads each immutable protected version, creating missing modules
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
case "$runtime" in /*) ;; *) runtime=$root/$runtime ;; esac
version=${BEE_VERSION:-}
version=${version#v}
[ -n "$version" ] || fail 'Set BEE_VERSION to the release version.'
visibility=${HUB_VISIBILITY:-private}
case "$visibility" in public | private) ;; *) fail "HUB_VISIBILITY must be public or private: $visibility" ;; esac

mkdir -p "$root/.wippy"
stage=$(mktemp -d "$root/.wippy/hub-publish.XXXXXXXX")
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT HUP INT TERM

WIPPY=$runtime BEE_VERSION=$version "$root/build/release-source.sh" "$stage/source"

# Each physical module directory declares its Hub identity in wippy.yaml.
for manifest in "$stage/source"/modules/*/wippy.yaml; do
    organization=$(awk '$1 == "organization:" { print $2; exit }' "$manifest")
    module=$(awk '$1 == "module:" { print $2; exit }' "$manifest")
    [ -n "$organization" ] && [ -n "$module" ] || fail "module identity is missing: $manifest"
    printf '%s/%s %s\n' "$organization" "$module" "$(dirname -- "$manifest")"
done > "$stage/modules.tsv"

# Dependencies publish before their dependents: tsort orders each module after
# the sibling Bee modules its ns.dependency entries name.
while read -r module directory; do
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

publish() {
    directory=$1
    if [ "$mode" = check ]; then
        (cd "$directory" && TMPDIR=$stage "$runtime" publish --dry-run --version "$version" < /dev/null)
    else
        (cd "$directory" && TMPDIR=$stage "$runtime" publish --version "$version" --create --protected \
            --module-visibility "$visibility" < /dev/null)
    fi
}

count=0
while read -r module; do
    directory=$(awk -v module="$module" '$1 == module { print $2; exit }' "$stage/modules.tsv")
    publish "$directory"
    printf 'hub publish: %s %s %s\n' "$mode" "$module" "$version"
    count=$((count + 1))
done < "$stage/order.txt"
publish "$stage/source"
printf 'hub publish: %s bee/bee %s\n' "$mode" "$version"
printf 'hub publish: %s %s modules at %s\n' "$mode" "$((count + 1))" "$version"
