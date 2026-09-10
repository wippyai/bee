#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Install Bee from a published GitHub release.

Usage: sh install.sh [--version VERSION] [--dir DIRECTORY]

  --version VERSION  Release version, with or without v (default: latest stable)
  --dir DIRECTORY    Installation directory (default: $HOME/.local/bin)
  -h, --help         Show this help
EOF
}

fail() { printf 'bee install: %s\n' "$*" >&2; exit 1; }

version=latest
destination=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|--dir)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
            case "$1" in
                --version) version=$2 ;;
                --dir) destination=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

if [ -z "$destination" ]; then
    [ -n "${HOME:-}" ] || fail 'HOME is unset; use --dir'
    destination=$HOME/.local/bin
fi
case "$destination" in
    /*) ;;
    *) destination=$PWD/$destination ;;
esac

case "$(uname -s)" in
    Linux) platform=linux ;;
    Darwin) platform=darwin ;;
    *) fail 'supported systems: Linux and macOS' ;;
esac
case "$(uname -m)" in
    x86_64|amd64) architecture=amd64 ;;
    aarch64|arm64) architecture=arm64 ;;
    *) fail 'supported architectures: amd64 and arm64' ;;
esac
command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v tar >/dev/null 2>&1 || fail 'tar is required'
if command -v sha256sum >/dev/null 2>&1; then
    checksum_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    checksum_tool=shasum
else
    fail 'sha256sum or shasum is required'
fi

release_url=https://github.com/wippyai/bee/releases
if [ "$version" = latest ]; then
    release_url=$release_url/latest/download
else
    version=${version#v}
    number='(0|[1-9][0-9]*)'
    identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    printf '%s\n' "$version" | LC_ALL=C grep -Eq "^$number\.$number\.$number(-$identifier(\.$identifier)*)?$" || fail 'invalid release version'
    release_url=$release_url/download/v$version
fi

temporary=$(mktemp -d "${TMPDIR:-/tmp}/bee-install.XXXXXXXX")
staged=
cleanup() {
    [ -z "$staged" ] || rm -f "$staged"
    rm -rf "$temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
archive=bee-$platform-$architecture.tar.gz
printf 'Downloading Bee (%s/%s, %s)…\n' "$platform" "$architecture" "$version"
for asset in "$archive" "$archive.sha256"; do
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 600 --retry 2 \
        --output "$temporary/$asset" "$release_url/$asset" || fail "could not download $asset; check that the release is published"
done

# Verify only the expected archive, even if the checksum document is malformed.
expected=$(awk -v name="$archive" 'NF == 2 && $2 == name { print $1 }' "$temporary/$archive.sha256")
[ "${#expected}" -eq 64 ] || fail 'invalid checksum document'
case "$expected" in *[!0-9a-fA-F]*) fail 'invalid checksum value' ;; esac
if [ "$checksum_tool" = sha256sum ]; then
    actual=$(sha256sum "$temporary/$archive" | awk '{ print $1 }')
else
    actual=$(shasum -a 256 "$temporary/$archive" | awk '{ print $1 }')
fi
[ "$expected" = "$actual" ] || fail 'archive checksum mismatch'

mkdir -p "$destination"
[ ! -d "$destination/bee" ] || fail 'destination bee is a directory'
staged=$(mktemp "$destination/.bee-install.XXXXXXXX")
tar -xOzf "$temporary/$archive" bee > "$staged" || fail 'archive does not contain Bee'
[ -s "$staged" ] || fail 'archive contains an empty binary'
chmod 755 "$staged"
mv -f "$staged" "$destination/bee"
staged=
printf 'Installed %s/bee\n' "$destination"
case ":${PATH:-}:" in
    *":$destination:"*) ;;
    *) printf 'Add %s to PATH to run bee.\n' "$destination" ;;
esac
