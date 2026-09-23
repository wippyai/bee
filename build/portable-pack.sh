#!/bin/sh
# SPDX-License-Identifier: MIT
# Build Bee's real physical module packs and a sealed multi-pack manifest.
set -eu

fail() {
    printf 'portable pack: %s\n' "$*" >&2
    exit 1
}

replace_pointer() {
    source=$1
    target=$2
    host=$(uname -s)
    case "$host" in
        Linux) mv -Tf "$source" "$target" ;;
        Darwin) mv -fh "$source" "$target" ;;
        *) fail "atomic portable deployment pointer replacement is unsupported: $host" ;;
    esac
}

root=$(
    CDPATH=
    export CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
runtime=${WIPPY:-$root/.wippy/bin/bee-wippy}
input_manifest=${BEE_BUILD_MANIFEST:-wippy.build.json}
output_manifest=${BEE_BUNDLE_MANIFEST:-dist/bee.bundle.build.json}

case "$runtime" in /*) ;; *) runtime=$root/$runtime ;; esac
case "$input_manifest" in /*) ;; *) input_manifest=$root/$input_manifest ;; esac
case "$output_manifest" in /*) ;; *) output_manifest=$root/$output_manifest ;; esac

[ -x "$runtime" ] || fail "Wippy toolchain is missing: $runtime"
[ -f "$input_manifest" ] || fail "build manifest is missing: $input_manifest"

mkdir -p "$(dirname -- "$output_manifest")"
output_dir=$(
    CDPATH=
    export CDPATH
    cd -- "$(dirname -- "$output_manifest")" && pwd
)
version=${BEE_VERSION:-$(awk -F'"' '/"module": "bee\/bee"/{seen=1} seen && /"version":/{print $4; exit}' "$input_manifest")}
[ -n "$version" ] || fail 'could not determine bee/bee version'
version=${version#v}

stage=$(mktemp -d "$output_dir/.bee-portable-pack.XXXXXXXX")
manifest_stage=
pointer_stage=
cleanup() {
    [ -z "$manifest_stage" ] || rm -f "$manifest_stage"
    if [ -n "$pointer_stage" ] && [ -L "$pointer_stage" ]; then
        rm -f "$pointer_stage"
    fi
    rm -rf "$stage"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$stage/artifacts/packs/bee"
# --module selects each physical module from the release source, which names
# bee/bee and every Bee module at this version.
WIPPY=$runtime BEE_BUILD_MANIFEST=$input_manifest BEE_VERSION=$version "$root/build/release-source.sh" "$stage/source"
mkdir -p "$stage/source/.portable-packs/bee"

awk '
    $1 == "-" && $2 == "name:" { name = $3; next }
    name != "" && $1 == "version:" { print name, $2; name = "" }
' "$stage/source/wippy.lock" > "$stage/modules.tsv"

while read -r module module_version; do
    name=${module#bee/}
    pack=$stage/artifacts/packs/bee/$name-$module_version.wapp
    staged_pack=.portable-packs/bee/$name-$module_version.wapp
    (cd "$stage/source" && "$runtime" pack --module "$module" "$staged_pack" --silent)
    mv "$stage/source/$staged_pack" "$pack"
done < "$stage/modules.tsv"

# Runtime patches remain byte-for-byte inputs to the pinned builder and travel
# beside the packs in the immutable generation.
sed -n 's/.*"path": "\(build\/patches\/[^" ]*\)".*/\1/p' "$input_manifest" | while read -r patch; do
    mkdir -p "$stage/artifacts/$(dirname -- "$patch")"
    cp "$root/$patch" "$stage/artifacts/$patch"
done

generation=$(cd "$stage/artifacts" && find . -type f -print | LC_ALL=C sort | while read -r artifact; do sha256sum "$artifact"; done | sha256sum | awk '{print $1}')
generation_dir=$output_dir/native-packs/$generation
if [ -e "$generation_dir" ]; then
    diff -r "$stage/artifacts" "$generation_dir" >/dev/null || fail "sealed generation differs: $generation_dir"
else
    mkdir -p "$output_dir/native-packs"
    mv "$stage/artifacts" "$generation_dir"
fi

mkdir -p "$stage/deployment/empty" "$stage/deployment/.wippy/vendor/bee"
printf '%s\n' 'directories:' '  modules: .wippy' '  src: ./empty' 'modules:' > "$stage/deployment/wippy.lock"
while read -r module module_version; do
    name=${module#bee/}
    pack=$generation_dir/packs/bee/$name-$module_version.wapp
    hash=$(sha256sum "$pack" | awk '{print $1}')
    cp "$pack" "$stage/deployment/.wippy/vendor/bee/$name-$module_version.wapp"
    printf '  - name: %s\n    version: %s\n    hash: sha256:%s\n' "$module" "$module_version" "$hash" >> "$stage/deployment/wippy.lock"
    [ "$module" != bee/bee ] || printf '%s\n' '    root: true' >> "$stage/deployment/wippy.lock"
done < "$stage/modules.tsv"
printf '%s\n' "version: '1.0'" 'registry:' '  enable_history: true' '  history_type: sqlite' \
    '  history_path: .wippy/registry.db' 'shutdown:' '  timeout: 3s' > "$stage/deployment/.wippy.yaml"

deployment_dir=$output_dir/portable-deployments/$generation
if [ -e "$deployment_dir" ]; then
    diff -r "$stage/deployment" "$deployment_dir" >/dev/null || fail "sealed deployment differs: $deployment_dir"
else
    mkdir -p "$output_dir/portable-deployments"
    mv "$stage/deployment" "$deployment_dir"
fi

packs=$stage/packs.json
while read -r module module_version; do
    name=${module#bee/}
    path=native-packs/$generation/packs/bee/$name-$module_version.wapp
    printf '%s\n' '      {' "        \"module\": \"$module\"," "        \"version\": \"$module_version\"," \
        "        \"path\": \"$path\"," '        "sha256": "0000000000000000000000000000000000000000000000000000000000000000"' '      },' >> "$packs"
done < "$stage/modules.tsv"
sed '$ s/},/}/' "$packs" > "$stage/packs.final.json"
mv "$stage/packs.final.json" "$packs"

manifest_stage=$(mktemp "$output_dir/.bee-bundle-manifest.XXXXXXXX")
awk -v packs="$packs" -v generation="native-packs/$generation/" '
    /^[[:space:]]*"packs": \[/ {
        print
        while ((getline line) > 0 && line !~ /^[[:space:]]*],$/) {}
        while ((getline pack < packs) > 0) print pack
        close(packs)
        print "    ],"
        next
    }
    /"path": "build\/patches\// {
        sub("build/patches/", generation "build/patches/")
    }
    { print }
' "$input_manifest" > "$manifest_stage"

(cd "$root" && env GOWORK=off GOTOOLCHAIN=go1.27.0 go run build/bootstrap.go seal "$manifest_stage" --version "$version")
(cd "$root" && env GOWORK=off GOTOOLCHAIN=go1.27.0 go run build/bootstrap.go validate "$manifest_stage")
mv "$manifest_stage" "$output_manifest"
staged_pointer=$output_dir/.portable-deployment-$generation
if [ -L "$staged_pointer" ]; then
    rm -f "$staged_pointer"
elif [ -e "$staged_pointer" ]; then
    fail "portable deployment staged pointer is not a symlink: $staged_pointer"
fi
ln -s "portable-deployments/$generation" "$staged_pointer"
pointer_stage=$staged_pointer
pointer=$output_dir/portable-deployment
if [ ! -L "$pointer" ] && [ -e "$pointer" ]; then
    fail "portable deployment pointer is not a symlink: $pointer"
fi
replace_pointer "$pointer_stage" "$pointer"
pointer_stage=
printf 'Packed %s physical Bee modules into %s\n' "$(wc -l < "$stage/modules.tsv" | tr -d ' ')" "$generation_dir"
