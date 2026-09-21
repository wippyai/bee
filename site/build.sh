#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
out="$root/dist/site"
rm -rf "$out"
mkdir -p "$out"

# The checked-in simulator is already a browser-ready single file. Copying
# it byte-for-byte keeps ordinary builds independent of a frontend toolchain.
if command -v sha256sum >/dev/null 2>&1; then
  hash=$(sha256sum "$root/site/bee-sim.js" | cut -c1-10)
elif command -v shasum >/dev/null 2>&1; then
  hash=$(shasum -a 256 "$root/site/bee-sim.js" | cut -c1-10)
else
  printf '%s\n' 'site build: sha256sum or shasum is required' >&2
  exit 1
fi
cp "$root/site/bee-sim.js" "$out/bee-sim.$hash.js"
sed "s|<script src=\"bee-sim.js\"></script>|<script src=\"bee-sim.$hash.js\" defer></script>|" \
  "$root/site/index.html" > "$out/index.html"
printf 'User-agent: *\nAllow: /\nSitemap: https://bee.wippy.ai/sitemap.xml\n' > "$out/robots.txt"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://bee.wippy.ai/</loc></url></urlset>\n' > "$out/sitemap.xml"
cp "$root/site/og.png" "$out/og.png"
