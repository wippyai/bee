#!/bin/sh
# Build a minified, cache-busted copy of the site and upload it to the web host.
set -eu
cd "$(dirname "$0")"
out=dist
rm -rf "$out"; mkdir -p "$out"
npx --yes esbuild bee-sim.js --minify --target=es2020 --outfile="$out/bee-sim.min.js" --log-level=warning
hash=$(sha256sum "$out/bee-sim.min.js" | cut -c1-10)
mv "$out/bee-sim.min.js" "$out/bee-sim.$hash.js"
sed "s|<script src=\"bee-sim.js\"></script>|<script src=\"bee-sim.$hash.js\" defer></script>|" index.html > "$out/index.html"
cp ../../install.sh "$out/install.sh"
cp ../../install.ps1 "$out/install.ps1"
printf 'User-agent: *\nAllow: /\nSitemap: https://bee.wippy.ai/sitemap.xml\n' > "$out/robots.txt"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://bee.wippy.ai/</loc><lastmod>%s</lastmod></url></urlset>\n' "$(date -u +%Y-%m-%d)" > "$out/sitemap.xml"
[ -f og.png ] && cp og.png "$out/og.png"
scp -q "$out"/* bee-web:/var/www/bee/
echo "deployed bee-sim.$hash.js"
