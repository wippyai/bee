#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
out="$root/dist/site"
: "${SITE_HOST:?Set SITE_HOST to the approved publication host}"
destination=${SITE_DEST:-/var/www/bee}

test -d "$out" || {
  printf 'site publication: %s is missing; run make site-build first\n' "$out" >&2
  exit 1
}
scp -q "$out"/* "$SITE_HOST:$destination/"
