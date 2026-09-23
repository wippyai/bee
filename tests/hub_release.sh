#!/bin/sh
# SPDX-License-Identifier: MIT
# Exercise build/hub-release.sh against a mocked GitHub CLI: a release's
# deployment is restored only when both archive checksums hold and its lock
# pins exactly the packs the executable's provenance records.
set -eu

fail() { printf 'hub release fixture: %s\n' "$*" >&2; exit 1; }

root=$(
    CDPATH=
    export CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
mkdir -p "$root/.wippy"
fixture=$(mktemp -d "$root/.wippy/hub-release-fixture.XXXXXXXX")
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT HUP INT TERM
tag=v0.0.1-alpha.1

# A release: the deployment archive, and the Linux archive whose provenance
# records the pack hashes. PROVENANCE_HASH overrides the bee/threads hash.
release() {
    assets=$1
    rm -rf "$assets" "$fixture/build"
    mkdir -p "$assets" "$fixture/build/deployment" "$fixture/build/binary"
    printf '%s\n' 'modules:' > "$fixture/build/deployment/wippy.lock"
    packs=
    for module in bee threads; do
        hash=$(printf 'sealed %s\n' "$module" | sha256sum | awk '{print $1}')
        printf '  - name: bee/%s\n    version: %s\n    hash: sha256:%s\n' "$module" "${tag#v}" "$hash" >> "$fixture/build/deployment/wippy.lock"
        [ "$module" != threads ] || hash=${PROVENANCE_HASH:-$hash}
        packs="$packs${packs:+,}{\"module\":\"bee/$module\",\"version\":\"${tag#v}\",\"sha256\":\"$hash\"}"
    done
    printf '{"manifest":{"application":{"packs":[%s]}}}\n' "$packs" > "$fixture/build/binary/bee.provenance.json"
    printf 'executable\n' > "$fixture/build/binary/bee"
    tar -czf "$assets/bee-deployment.tar.gz" -C "$fixture/build/deployment" .
    tar -czf "$assets/bee-linux-amd64.tar.gz" -C "$fixture/build/binary" bee bee.provenance.json
    (cd "$assets" && sha256sum bee-deployment.tar.gz > bee-deployment.tar.gz.sha256 &&
        sha256sum bee-linux-amd64.tar.gz > bee-linux-amd64.tar.gz.sha256)
}

# The mock serves the fixture release's assets for the requested patterns.
mkdir -p "$fixture/bin"
cat > "$fixture/bin/gh" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_CALLS"
[ "$1 $2" = "release download" ] || exit 1
[ "$3" = "$MOCK_TAG" ] || { echo "release not found" >&2; exit 1; }
shift 3
directory=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir) shift; directory=$1 ;;
        --pattern) shift; cp "$MOCK_ASSETS/$1" "$directory/$1" ;;
    esac
    shift
done
MOCK
chmod +x "$fixture/bin/gh"

run() {
    : > "$fixture/calls"
    PATH="$fixture/bin:$PATH" MOCK_CALLS="$fixture/calls" MOCK_TAG=$tag MOCK_ASSETS="$fixture/published" \
        "$root/build/hub-release.sh" "$1" "$fixture/restore" > "$fixture/out" 2>&1
}

release "$fixture/published"
run "$tag" || { cat "$fixture/out" >&2; fail 'a coherent release was refused'; }
grep -q "^release download $tag --dir $fixture/restore/assets --pattern bee-deployment.tar.gz --pattern bee-deployment.tar.gz.sha256 --pattern bee-linux-amd64.tar.gz --pattern bee-linux-amd64.tar.gz.sha256\$" "$fixture/calls" ||
    fail 'the release assets were not downloaded from the named release'
grep -q "^  - name: bee/threads" "$fixture/restore/deployment/wippy.lock" || fail 'the deployment was not extracted'

HUB_RELEASE_ASSETS="$fixture/published" run "$tag" || { cat "$fixture/out" >&2; fail 'local release assets were refused'; }
[ ! -s "$fixture/calls" ] || fail 'local release assets still downloaded from GitHub'
cmp -s "$fixture/published/bee-deployment.tar.gz" "$fixture/restore/assets/bee-deployment.tar.gz" || fail 'local assets were not used'

run v9.9.9 && fail 'an unknown release was restored'
grep -q 'cannot download the assets of release v9.9.9' "$fixture/out" || fail 'a missing release was not named'

printf 'tampered\n' >> "$fixture/published/bee-deployment.tar.gz"
run "$tag" && fail 'a deployment archive that differs from its checksum was restored'
grep -q 'bee-deployment.tar.gz does not match its release checksum' "$fixture/out" || fail 'the checksum mismatch was not named'
[ ! -f "$fixture/restore/deployment/wippy.lock" ] || fail 'a stale deployment survived a refused restore'

PROVENANCE_HASH=0000000000000000000000000000000000000000000000000000000000000000 release "$fixture/published"
run "$tag" && fail 'a deployment that differs from the executable provenance was restored'
grep -q "release deployment differs from the executable's embedded packs" "$fixture/out" || fail 'the provenance mismatch was not named'

printf '%s\n' 'Release restore downloads the named release, verifies both checksums and requires the deployment lock to match the executable provenance'
