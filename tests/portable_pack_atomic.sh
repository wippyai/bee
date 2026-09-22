#!/bin/sh
# SPDX-License-Identifier: MIT
# Exercise portable-pack's pointer swap with a mocked packer and builder.
set -eu

fail() { printf 'portable pack atomic fixture: %s\n' "$*" >&2; exit 1; }

root=$(
    CDPATH=
    export CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/bee-portable-pack-atomic.XXXXXXXX")
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT HUP INT TERM

mkdir -p "$fixture/tools" "$fixture/normal/portable-deployments/old"
cat > "$fixture/tools/wippy" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
    lint) ;;
    pack)
        output=
        module=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --module) shift; module=$1 ;;
                .portable-packs/*) output=$1 ;;
            esac
            shift
        done
        [ -n "$module" ] && [ -n "$output" ] || exit 1
        mkdir -p "$(dirname -- "$output")"
        printf '%s\n' "$module" > "$output"
        ;;
    *) exit 1 ;;
esac
EOF
cat > "$fixture/tools/go" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$fixture/tools/wippy" "$fixture/tools/go"

run_pack() {
    WIPPY="$fixture/tools/wippy" \
    BEE_BUILD_MANIFEST="$root/wippy.build.json" \
    BEE_BUNDLE_MANIFEST="$1/bee.bundle.build.json" \
    PATH="$2:$fixture/tools:/usr/bin:/bin" \
    "$root/build/portable-pack.sh"
}

ln -s portable-deployments/old "$fixture/normal/portable-deployment"
run_pack "$fixture/normal" "$fixture/tools"
first_target=$(readlink "$fixture/normal/portable-deployment")
[ "$first_target" != portable-deployments/old ] || fail 'active pointer was not replaced'
generation=${first_target#portable-deployments/}
[ -d "$fixture/normal/$first_target" ] || fail 'replacement pointer does not name deployment'

unlink "$fixture/normal/portable-deployment"
ln -s portable-deployments/old "$fixture/normal/portable-deployment"
ln -s stale "$fixture/normal/.portable-deployment-$generation"
run_pack "$fixture/normal" "$fixture/tools"
[ "$(readlink "$fixture/normal/portable-deployment")" = "$first_target" ] || fail 'stale stage recovery did not replace pointer'
[ ! -e "$fixture/normal/.portable-deployment-$generation" ] || fail 'stale staged pointer remains'

mkdir -p "$fixture/unsupported/portable-deployments/old" "$fixture/unsupported-tools"
ln -s portable-deployments/old "$fixture/unsupported/portable-deployment"
cat > "$fixture/unsupported-tools/uname" <<'EOF'
#!/bin/sh
printf '%s\n' Plan9
EOF
chmod +x "$fixture/unsupported-tools/uname"
if run_pack "$fixture/unsupported" "$fixture/unsupported-tools" > "$fixture/unsupported.out" 2>&1; then
    fail 'unsupported host accepted pointer replacement'
fi
grep -F 'atomic portable deployment pointer replacement is unsupported: Plan9' "$fixture/unsupported.out" >/dev/null || {
    cat "$fixture/unsupported.out" >&2
    fail 'unsupported host failure is unclear'
}
[ "$(readlink "$fixture/unsupported/portable-deployment")" = portable-deployments/old ] || fail 'unsupported host changed active pointer'

printf '%s\n' 'Portable pack atomic pointer replacement and failure preservation passed'
