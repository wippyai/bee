#!/bin/sh
# SPDX-License-Identifier: MIT
# Prove a deployed physical pack graph needs neither source nor network.
set -eu

fail() { printf 'portable deployment: %s\n' "$*" >&2; exit 1; }

root=$(
    CDPATH=
    export CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
runtime=${1:-$root/.wippy/bin/bee-wippy}
deployment=${2:-$root/dist/portable-deployment}
case "$runtime" in /*) ;; *) runtime=$root/$runtime ;; esac
case "$deployment" in /*) ;; *) deployment=$root/$deployment ;; esac
[ -x "$runtime" ] || fail "runtime is missing: $runtime"
[ -d "$deployment" ] || fail "deployment is missing: $deployment"

if [ "${BEE_PORTABLE_NAMESPACE:-}" != 1 ]; then
    command -v unshare >/dev/null 2>&1 || fail 'unshare is required for network isolation'
    if env -i PATH=/usr/bin:/bin unshare --user --map-root-user --net /bin/true; then
        exec env BEE_PORTABLE_NAMESPACE=1 PATH=/usr/bin:/bin unshare --user --map-root-user --net "$0" "$runtime" "$deployment"
    fi
    fail 'network namespace isolation is unavailable'
fi

command -v ip >/dev/null 2>&1 || fail 'ip is required to inspect network isolation'
[ "$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1)" = lo ] || fail 'network namespace is not loopback-only'
ip link set lo up

fixture=$(mktemp -d "${TMPDIR:-/tmp}/bee-portable-deployment.XXXXXXXX")
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT HUP INT TERM
cp -RL "$deployment" "$fixture/deploy"
deploy=$fixture/deploy

test ! -e "$deploy/src" || fail 'deployment retains a source path'
if ! test -d "$deploy/empty" || [ -n "$(find "$deploy/empty" -mindepth 1 -print -quit)" ]; then
    fail 'source placeholder is not empty'
fi
! grep -q 'replacements:' "$deploy/.wippy.yaml" || fail 'deployment config has local replacements'

awk '
    $1 == "-" && $2 == "name:" { name = $3; next }
    name != "" && $1 == "version:" { version = $2; next }
    name != "" && $1 == "hash:" { print name, version, $2; name = "" }
' "$deploy/wippy.lock" > "$fixture/modules.tsv"
[ "$(wc -l < "$fixture/modules.tsv" | tr -d ' ')" -gt 1 ] || fail 'portable lock does not contain a complete graph'

# Tamper a fresh copy before any registry state exists. The lock verifier must
# reject the changed payload before it attempts to load an application.
cp -RL "$deployment" "$fixture/tampered"
sed -n '2p' "$fixture/modules.tsv" | { read -r module version _; printf '%s %s\n' "$module" "$version"; } > "$fixture/tampered-module.txt"
read -r module version < "$fixture/tampered-module.txt"
name=${module#bee/}
tampered_pack=$fixture/tampered/.wippy/vendor/bee/$name-$version.wapp
# The installer verifies the lock digest before parsing the WAPP body. Alter
# the leading byte, as the portable runtime contract permits that check first.
printf '\001' | dd of="$tampered_pack" bs=1 seek=0 conv=notrunc status=none
if (cd "$fixture/tampered" && timeout 15s "$runtime" run --verbose --host bee:workers -- bee-host > "$fixture/tamper.out" 2>&1); then
    fail 'tampered vendor pack loaded'
fi
grep -q 'module integrity verification failed' "$fixture/tamper.out" || { cat "$fixture/tamper.out" >&2; fail 'tamper failure lacks integrity evidence'; }
grep -q 'expected' "$fixture/tamper.out" || { cat "$fixture/tamper.out" >&2; fail 'tamper failure lacks expected digest evidence'; }
grep -q 'actual' "$fixture/tamper.out" || { cat "$fixture/tamper.out" >&2; fail 'tamper failure lacks actual digest evidence'; }

expected_entries=0
: > "$fixture/expected-vendor.txt"
while read -r module version expected_hash; do
    name=${module#bee/}
    pack=$deploy/.wippy/vendor/bee/$name-$version.wapp
    [ -f "$pack" ] || fail "missing pack: $module@$version"
    printf '.wippy/vendor/bee/%s-%s.wapp\n' "$name" "$version" >> "$fixture/expected-vendor.txt"
    actual_hash=sha256:$(sha256sum "$pack" | awk '{print $1}')
    [ "$actual_hash" = "$expected_hash" ] || fail "hash does not match lock: $module"

    single=$fixture/$(printf '%s' "$name" | tr / _)
    mkdir -p "$single/empty" "$single/.wippy/vendor/bee"
    cp "$pack" "$single/.wippy/vendor/bee/$name-$version.wapp"
    printf '%s\n' 'directories:' '  modules: .wippy' '  src: ./empty' 'modules:' \
        "  - name: $module" "    version: $version" "    hash: $expected_hash" '    root: true' > "$single/wippy.lock"
    (cd "$single" && "$runtime" registry list --json > "$single/entries.json")
    definitions=$(grep -c '"kind": "ns.definition"' "$single/entries.json" || true)
    [ "$definitions" = 1 ] || fail "$module has $definitions namespace definitions"
    case "$module" in
        bee/bee) source=$root/src/_index.yaml ;;
        bee/governance) source=$root/modules/gov/src/_index.yaml ;;
        *) source=$root/modules/$name/src/_index.yaml ;;
    esac
    expected_namespace=$(awk -F': ' '/^namespace:/{print $2; exit}' "$source")
    actual_namespace=$(awk -F'"' '/^    "id":/{id=$4} /"kind": "ns.definition"/{print id}' "$single/entries.json" | cut -d: -f1)
    [ "$actual_namespace" = "$expected_namespace" ] || fail "$module definition is $actual_namespace, expected $expected_namespace"
    test_entries=$(cd "$single" && "$runtime" registry list --meta 'type=test' --json)
    support_entries=$(cd "$single" && "$runtime" registry list --meta 'test_support=true' --json)
    [ "$test_entries" = '[]' ] || fail "$module contains test entries"
    [ "$support_entries" = '[]' ] || fail "$module contains test_support entries"
    count=$(grep -c '^    "id":' "$single/entries.json" || true)
    expected_entries=$((expected_entries + count))
done < "$fixture/modules.tsv"

(cd "$deploy" && find .wippy/vendor -type f -name '*.wapp' -print | LC_ALL=C sort) > "$fixture/actual-vendor.txt"
LC_ALL=C sort "$fixture/expected-vendor.txt" > "$fixture/expected-vendor.sorted.txt"
diff -u "$fixture/expected-vendor.sorted.txt" "$fixture/actual-vendor.txt" >/dev/null || fail 'vendor WAPP set differs from exact lock coverage'

(cd "$deploy" && "$runtime" registry list --json > "$fixture/all-entries.json")
actual_entries=$(grep -c '^    "id":' "$fixture/all-entries.json" || true)
[ "$actual_entries" = "$expected_entries" ] || fail "registry coverage is $actual_entries, expected $expected_entries"
identities=$(awk -F'"' '/^    "id":/{print $4}' "$fixture/all-entries.json")
[ "$(printf '%s\n' "$identities" | sort | uniq | wc -l | tr -d ' ')" = "$actual_entries" ] || fail 'registry has duplicate identities'

boot() {
    log=$1
    (cd "$deploy" && exec env -i HOME="$fixture/home" PATH=/usr/bin:/bin TERM=xterm-256color LC_ALL=C.UTF-8 "$runtime" run --verbose --host bee:workers -- bee-host > "$log" 2>&1) &
    pid=$!
    ready=
    for _ in $(seq 1 300); do
        if grep -q 'Bee workspace ready' "$log" 2>/dev/null; then ready=1; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    [ -n "$ready" ] || { cat "$log" >&2; fail 'headless boot did not reach Bee workspace ready'; }
    workspace=$(sed -n 's/.*"workspace_id": "\([^"]*\)".*/\1/p' "$log" | tail -1)
    [ -n "$workspace" ] || fail 'headless ready event did not contain workspace identity'
    kill -TERM "$pid"
    wait "$pid" || { cat "$log" >&2; fail 'headless process did not shut down cleanly'; }
    printf '%s\n' "$workspace"
}

first=$(boot "$fixture/first.log")
second=$(boot "$fixture/second.log")
[ "$first" = "$second" ] || fail "workspace identity changed across boot: $first != $second"

printf 'Portable deployment: %s exact WAPPs, source-free network-isolated boot/reboot, inspection and tamper rejection passed\n' "$(wc -l < "$fixture/modules.tsv" | tr -d ' ')"
