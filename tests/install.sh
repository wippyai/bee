#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/bee-installer-test.XXXXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/assets" "$fixture/source"
printf 'test binary\n' > "$fixture/source/bee"
tar -czf "$fixture/assets/bee-linux-amd64.tar.gz" -C "$fixture/source" bee
cd "$fixture/assets"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum bee-linux-amd64.tar.gz > bee-linux-amd64.tar.gz.sha256
else
    shasum -a 256 bee-linux-amd64.tar.gz > bee-linux-amd64.tar.gz.sha256
fi
cat > "$fixture/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) exit 1 ;; esac
EOF
cat > "$fixture/bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=
for argument do
    if [ "${previous:-}" = --output ]; then output=$argument; fi
    previous=$argument
done
case "$argument" in
    https://github.com/wippyai/bee/releases/download/v1.2.3/bee-linux-amd64.tar.gz*) ;;
    *) exit 1 ;;
esac
cp "$INSTALL_FIXTURE/assets/${argument##*/}" "$output"
EOF
chmod +x "$fixture/bin/uname" "$fixture/bin/curl"
export INSTALL_FIXTURE="$fixture"
export PATH="$fixture/bin:$PATH"

sh "$root/install.sh" --version v1.2.3 --dir "$fixture/install space"
cmp "$fixture/source/bee" "$fixture/install space/bee"
test -x "$fixture/install space/bee"

printf 'tampered' >> "$fixture/assets/bee-linux-amd64.tar.gz"
if sh "$root/install.sh" --version 1.2.3 --dir "$fixture/install space" > "$fixture/failure.log" 2>&1; then
    echo 'installer accepted a corrupt archive' >&2
    exit 1
fi
grep -q 'archive checksum mismatch' "$fixture/failure.log"
cmp "$fixture/source/bee" "$fixture/install space/bee"

for version in ../main 01.2.3 '1.2.3/extra' '1.2.3-01'; do
    if sh "$root/install.sh" --version "$version" --dir "$fixture/rejected" > "$fixture/failure.log" 2>&1; then
        echo 'installer accepted an invalid version' >&2
        exit 1
    fi
    grep -q 'invalid release version' "$fixture/failure.log"
done
test ! -e "$fixture/rejected"
printf 'Installer: download, checksum, install, and failure preservation passed\n'
