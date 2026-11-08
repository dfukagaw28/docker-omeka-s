#!/bin/sh
# Convert images for IIIF delivery with libvips.
#
#   make-tiles.sh static <base-url> <out-dir> <image>...
#       Static IIIF Level 0 tiles (no image server needed; serve <out-dir>
#       with Caddy's file_server). Creates <out-dir>/<name>/info.json + tiles.
#       <base-url> is the public URL of <out-dir>, e.g.
#       https://example.org/iiif-img  ->  https://example.org/iiif-img/<name>/info.json
#
#   make-tiles.sh ptif <out-dir> <image>...
#       Pyramidal TIFFs for the IIPImage server (compose profile "iiif").
#       Put them in IIIF_IMAGE_DIR; served as /iiif/<name>.tif/info.json
#
# <name> is the input file name without its extension.
# Register the resulting info.json URL in Omeka S as an "IIIF image" media.
#
# Environment:
#   TILE_SIZE  tile size in pixels (default 512)
#   QUALITY    JPEG quality (default 90)
set -eu

TILE_SIZE="${TILE_SIZE:-512}"
QUALITY="${QUALITY:-90}"

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

command -v vips >/dev/null || { echo "vips not found (apt install libvips-tools)" >&2; exit 1; }

mode="${1:-}"; [ $# -gt 0 ] && shift
case "$mode" in
    static)
        [ $# -ge 3 ] || usage
        base_url="${1%/}"; out_dir="$2"; shift 2
        mkdir -p "$out_dir"
        for src in "$@"; do
            name="$(basename "${src%.*}")"
            echo "static: $src -> $out_dir/$name"
            rm -rf "${out_dir:?}/$name"
            vips dzsave "$src" "$out_dir/$name" \
                --layout iiif3 --id "$base_url" \
                --tile-size "$TILE_SIZE" --overlap 0 \
                --suffix ".jpg[Q=$QUALITY]"
        done
        ;;
    ptif)
        [ $# -ge 2 ] || usage
        out_dir="$1"; shift
        mkdir -p "$out_dir"
        for src in "$@"; do
            name="$(basename "${src%.*}")"
            echo "ptif: $src -> $out_dir/$name.tif"
            vips tiffsave "$src" "$out_dir/$name.tif" \
                --tile --pyramid --tile-width 256 --tile-height 256 \
                --compression jpeg --Q "$QUALITY"
        done
        ;;
    *) usage ;;
esac
