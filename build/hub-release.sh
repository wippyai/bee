#!/bin/sh
# SPDX-License-Identifier: MIT
# Restore one GitHub release's Bee deployment for Hub publication.
#
# Usage: build/hub-release.sh TAG DIRECTORY
#
# Downloads bee-deployment.tar.gz and bee-linux-amd64.tar.gz with their
# .sha256 documents from the release TAG (drafts included; listing a draft
# requires push access), verifies both checksums, extracts the deployment to
# DIRECTORY/deployment and requires its lock to pin exactly the packs and
# hashes the executable's bee.provenance.json records. HUB_RELEASE_ASSETS names
# a directory that already holds those four assets instead of downloading them.
set -eu

fail() {
    printf 'hub release: %s\n' "$*" >&2
    exit 1
}

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    fail 'usage: build/hub-release.sh TAG DIRECTORY'
fi
tag=$1
directory=$2
assets=$directory/assets
deployment=$directory/deployment
archives='bee-deployment.tar.gz bee-linux-amd64.tar.gz'

rm -rf "$assets" "$deployment"
mkdir -p "$assets" "$deployment"
if [ -n "${HUB_RELEASE_ASSETS:-}" ]; then
    for archive in $archives; do
        for file in "$archive" "$archive.sha256"; do
            [ -f "$HUB_RELEASE_ASSETS/$file" ] || fail "release asset is missing: $HUB_RELEASE_ASSETS/$file"
            cp "$HUB_RELEASE_ASSETS/$file" "$assets/$file"
        done
    done
else
    command -v gh > /dev/null || fail 'the GitHub CLI (gh) is required to download the release assets'
    set --
    for archive in $archives; do
        set -- "$@" --pattern "$archive" --pattern "$archive.sha256"
    done
    gh release download "$tag" --dir "$assets" "$@" || fail "cannot download the assets of release $tag"
fi

for archive in $archives; do
    [ -f "$assets/$archive.sha256" ] || fail "release $tag has no $archive.sha256"
    (cd "$assets" && sha256sum --check --strict "$archive.sha256" > /dev/null) || fail "$archive does not match its release checksum"
done
tar -xzf "$assets/bee-deployment.tar.gz" -C "$deployment"
tar -xzf "$assets/bee-linux-amd64.tar.gz" -C "$assets" bee.provenance.json || fail "bee-linux-amd64.tar.gz has no bee.provenance.json"
[ -f "$deployment/wippy.lock" ] || fail "bee-deployment.tar.gz of $tag has no wippy.lock"

# The release deployment holds the sealed packs every release executable
# embeds; provenance proves it before any upload.
python3 - "$assets/bee.provenance.json" "$deployment/wippy.lock" <<'PY'
import json, re, sys
embedded = {pack["module"]: (pack["version"], "sha256:" + pack["sha256"])
            for pack in json.load(open(sys.argv[1]))["manifest"]["application"]["packs"]}
locked = dict((name, (version, digest)) for name, version, digest in re.findall(
    r"- name: (\S+)\n\s+version: (\S+)\n\s+hash: (\S+)", open(sys.argv[2]).read()))
if embedded != locked:
    sys.exit(f"hub release: release deployment differs from the executable's embedded packs: {embedded} != {locked}")
PY
printf 'hub release: %s deployment restored to %s; checksums and provenance verified\n' "$tag" "$deployment"
