#!/bin/sh
# SPDX-License-Identifier: MIT
# Prove the native module pin in a build manifest names the tagged commit's
# native tree. A release must assemble the tree under review; a proxy pin
# that still points at an older revision would silently build stale native code.
#
# usage: build/native-pin.sh <manifest> <tagged-commit>
set -eu

fail() {
    printf 'native pin: %s\n' "$*" >&2
    exit 1
}

manifest=$1
tagged=$2

[ -f "$manifest" ] || fail "manifest is missing: $manifest"
git rev-parse --verify --quiet "$tagged^{commit}" >/dev/null || fail "tagged commit is not in this repository: $tagged"

module=$(awk -F'"' '
    /^[[:space:]]*"native":[[:space:]]*\[/ { native = 1; next }
    native && /^[[:space:]]*]/ { exit }
    native && /"module":[[:space:]]*"/ { print $4; exit }
' "$manifest")
version=$(awk -F'"' '
    /^[[:space:]]*"native":[[:space:]]*\[/ { native = 1; next }
    native && /^[[:space:]]*]/ { exit }
    native && /"version":[[:space:]]*"/ { print $4; exit }
' "$manifest")
[ "$module" = "github.com/wippyai/bee/native" ] || fail "unexpected native module: $module"
[ -n "$version" ] || fail "native version is missing: $manifest"

revision=$(printf '%s\n' "$version" | sed -n 's/^v0\.0\.0-\([0-9]\{14\}\)-\([0-9a-f]\{12\}\)$/\2/p')
[ -n "$revision" ] || fail "native pin is not a v0.0.0 timestamp revision: $version"
timestamp=$(printf '%s\n' "$version" | sed -n 's/^v0\.0\.0-\([0-9]\{14\}\)-[0-9a-f]\{12\}$/\1/p')

pinned=$(git rev-parse --verify --quiet "$revision^{commit}") || fail "pinned native revision does not resolve: $revision"
git merge-base --is-ancestor "$pinned" "$tagged" || fail "pinned native revision $revision is not an ancestor of $tagged"

recorded=$(TZ=UTC git show -s --format=%cd --date=format-local:%Y%m%d%H%M%S "$pinned")
[ "$recorded" = "$timestamp" ] || fail "native pin timestamp $timestamp does not match commit $pinned ($recorded)"

pinned_tree=$(git rev-parse "$pinned:native")
tagged_tree=$(git rev-parse "$tagged:native")
[ "$pinned_tree" = "$tagged_tree" ] || fail "native pin $revision does not name the tree at $tagged"

printf 'Native pin %s resolves to %s and matches %s\n' "$version" "$pinned" "$tagged"
