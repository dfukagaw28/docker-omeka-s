#!/bin/sh
# Download a GitHub release asset.
#   fetch-release.sh <url> <output>
# Tries the URL directly first. If it is a github.com release download URL and
# the direct download fails (e.g. 5xx from github.com), falls back to the
# GitHub REST API asset endpoint (api.github.com), which serves the same file.
set -eu
url="$1"; out="$2"

if curl -fsSL --retry 3 --retry-all-errors -o "$out" "$url"; then
    exit 0
fi

# https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
path="${url#https://github.com/}"
[ "$path" != "$url" ] || exit 1
owner_repo="$(echo "$path" | cut -d/ -f1-2)"
tag="$(echo "$path" | cut -d/ -f5)"
file="$(echo "$path" | cut -d/ -f6)"

echo "fetch-release: direct download failed, trying the GitHub API for $owner_repo $tag $file" >&2
asset_url="$(curl -fsSL --retry 3 --retry-all-errors "https://api.github.com/repos/$owner_repo/releases/tags/$tag" \
    | php -r '$f = $argv[1]; foreach (json_decode(stream_get_contents(STDIN), true)["assets"] ?? [] as $a) { if ($a["name"] === $f) { echo $a["url"]; exit(0); } } exit(1);' "$file")"
curl -fsSL --retry 3 --retry-all-errors -H 'Accept: application/octet-stream' -o "$out" "$asset_url"
