#!/bin/sh
# SPDX-License-Identifier: MIT
# Exercise build/hub-publish.sh against a mocked Wippy publisher: sealed packs
# upload byte for byte in dependency order and every Hub digest must equal the
# release deployment's lock hash.
set -eu

fail() { printf 'hub publish fixture: %s\n' "$*" >&2; exit 1; }

root=$(
    CDPATH=
    export CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
mkdir -p "$root/.wippy"
fixture=$(mktemp -d "$root/.wippy/hub-publish-fixture.XXXXXXXX")
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT HUP INT TERM
version=0.0.1-alpha.1

# The mock records each call and reports the digest of the pack it was given,
# or MOCK_DIGEST when a test needs the Hub to disagree.
cat > "$fixture/wippy" <<'MOCK'
#!/bin/sh
set -eu
[ "$1" = publish ] || exit 1
shift
config= wapp= arguments=$*
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config) shift; config=$1 ;;
        --wapp) shift; wapp=$1 ;;
    esac
    shift
done
[ -n "$config" ] && [ -f "$wapp" ] || exit 1
module=$(awk '$1 == "module:" { print $2; exit }' "$config/wippy.yaml")
printf '%s %s %s\n' "$module" "$(basename "$wapp")" "$arguments" >> "$MOCK_CALLS"
printf '  Digest: %s\n' "${MOCK_DIGEST:-sha256:$(sha256sum "$wapp" | awk '{print $1}')}"
MOCK
chmod +x "$fixture/wippy"

deploy() {
    target=$1
    lock_version=$2
    mkdir -p "$target/.wippy/vendor/bee"
    printf '%s\n' 'directories:' '  modules: .wippy' '  src: ./empty' 'modules:' > "$target/wippy.lock"
    for module in bee $(for manifest in "$root"/modules/*/wippy.yaml; do awk '$1 == "module:" { print $2 }' "$manifest"; done); do
        pack=$target/.wippy/vendor/bee/$module-$version.wapp
        printf 'sealed %s\n' "$module" > "$pack"
        printf '  - name: bee/%s\n    version: %s\n    hash: sha256:%s\n' "$module" "$lock_version" "$(sha256sum "$pack" | awk '{print $1}')" >> "$target/wippy.lock"
    done
}

run() {
    : > "$fixture/calls"
    MOCK_CALLS="$fixture/calls" WIPPY="$fixture/wippy" BEE_VERSION=$version BEE_DEPLOYMENT=$1 \
        HUB_VISIBILITY=public "$root/build/hub-publish.sh" "$2" > "$fixture/out" 2>&1
}

position() { grep -n "^$1 " "$fixture/calls" | cut -d: -f1; }

deploy "$fixture/release" "$version"
run "$fixture/release" check || { cat "$fixture/out" >&2; fail 'check refused a coherent release deployment'; }
[ "$(grep -c 'lock sha256:' "$fixture/out")" = 23 ] || fail 'check did not report 23 lock hash and digest pairs'
awk '$1 == "hub" && $4 ~ /^bee\// && $7 != $9 { exit 1 }' "$fixture/out" || fail 'a reported digest differs from its lock hash'
[ "$(wc -l < "$fixture/calls" | tr -d ' ')" = 23 ] || fail 'check did not dry-run every module'
[ "$(grep -c -- '--dry-run' "$fixture/calls")" = 23 ] || fail 'check uploaded without --dry-run'
! grep -q -- '--create' "$fixture/calls" || fail 'check requested module creation'
[ "$(tail -n 1 "$fixture/calls" | cut -d' ' -f1)" = bee ] || fail 'bee/bee is not published last'
[ "$(position persist)" -lt "$(position threads)" ] || fail 'bee/threads precedes its dependency bee/persist'
[ "$(position gateway)" -lt "$(position harness)" ] || fail 'bee/harness precedes its dependency bee/gateway'
grep -q "^gateway gateway-$version.wapp " "$fixture/calls" || fail 'the sealed gateway pack was not uploaded'

run "$fixture/release" publish || { cat "$fixture/out" >&2; fail 'publish refused a coherent release deployment'; }
[ "$(grep -c -- '--create --protected --module-visibility public' "$fixture/calls")" = 23 ] || fail 'publish did not create, protect and set visibility for every module'
! grep -q -- '--dry-run' "$fixture/calls" || fail 'publish ran a dry run'

MOCK_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000 run "$fixture/release" check && fail 'check accepted a Hub digest that differs from the lock hash'
grep -q 'differs from lock hash' "$fixture/out" || fail 'digest mismatch was not named'

deploy "$fixture/development" 0.1.0-dev
run "$fixture/development" check && fail 'check accepted a deployment locked at another version'
grep -q "locks bee/bee at 0.1.0-dev, not $version" "$fixture/out" || fail 'version mismatch was not named'

printf 'tampered\n' > "$fixture/release/.wippy/vendor/bee/sync-$version.wapp"
run "$fixture/release" check && fail 'check accepted a vendor pack that differs from its lock hash'
grep -q 'does not match the lock hash' "$fixture/out" || fail 'tampered pack was not named'

printf '%s\n' 'Hub publication uploads sealed packs in dependency order; digests, versions and pack bytes are checked against the lock'
