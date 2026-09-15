#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

fail() {
    printf 'offline boot: %s\n' "$*" >&2
    exit 1
}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary=${1:-}
[ -n "$binary" ] || fail 'usage: tests/offline_boot.sh BEE_BINARY'
[ "$(uname -s)" = Linux ] || fail 'Linux is required for network namespace isolation'
command -v unshare >/dev/null 2>&1 || fail 'unshare is required for network namespace isolation'
command -v ip >/dev/null 2>&1 || fail 'ip is required to inspect network namespace isolation'
python_bin=$(command -v python3) || fail 'python3 is required by the existing native acceptance helpers'
python_path=$("$python_bin" -c 'import site; print(site.getusersitepackages())') || fail 'could not resolve the Python helper site'
[ -x "$binary" ] || fail "Bee binary is not executable: $binary"

# Resolve this before entering the namespace so the child cannot accidentally
# resolve a different executable through a caller-controlled working directory.
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")

if [ "${BEE_OFFLINE_BOOT_NAMESPACE:-}" != 1 ]; then
    # A network namespace starts with only an unconfigured loopback device. The
    # inner invocation validates that state and brings loopback up for local
    # Bee client/owner communication.
    if env -i PATH=/usr/bin:/bin unshare --user --map-root-user --net /bin/true; then
        exec env BEE_OFFLINE_BOOT_NAMESPACE=1 BEE_OFFLINE_BOOT_PYTHON="$python_bin" \
            BEE_OFFLINE_BOOT_PYTHONPATH="$python_path" \
            unshare --user --map-root-user --net "$0" "$binary"
    else
        status=$?
        fail "network namespace isolation unavailable (unshare exit $status)"
    fi
fi

interfaces=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1)
[ "$interfaces" = lo ] || fail "network namespace is not loopback-only (interfaces: $interfaces)"
ip link set lo up
python_bin=${BEE_OFFLINE_BOOT_PYTHON:-}
[ -x "$python_bin" ] || fail 'isolated acceptance lost its Python interpreter path'
python_path=${BEE_OFFLINE_BOOT_PYTHONPATH:-}
[ -n "$python_path" ] || fail 'isolated acceptance lost its Python helper path'

# The existing helpers create temporary fixture directories and explicitly
# remove Bee state variables. Start Python with an empty environment as an
# additional guard against forwarding credentials or user store paths.
test_env=$(mktemp -d "${TMPDIR:-/tmp}/bee-offline-boot-env.XXXXXXXX")
trap 'rm -rf "$test_env"' EXIT HUP INT TERM
env -i HOME="$test_env" PATH=/usr/bin:/bin PYTHONPATH="$python_path" TERM=xterm-256color LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 "$python_bin" "$root/tests/native_binary.py" "$binary"
env -i HOME="$test_env" PATH=/usr/bin:/bin PYTHONPATH="$python_path" TERM=xterm-256color LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 "$python_bin" -c \
    'import pathlib, sys; sys.path.insert(0, sys.argv[1]); from native_client import run; run(pathlib.Path(sys.argv[2]).resolve())' \
    "$root/tests" "$binary"

printf 'Offline Bee: loopback-only fresh boot, restart and public retained-client reconnect passed\n'
