#!/usr/bin/env bash
#
# Renders Readeck's own artwork into Resources/AppIcon.icns.
#
# The source is the UNMODIFIED `logo-square.svg` from Readeck's repository, so
# the icon stays faithful to upstream and the only committed asset is text.
# macOS reads the SVG natively via NSImage, so this needs no Homebrew tooling.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="${ROOT}/Resources/logo-square.svg"
OUT="${ROOT}/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[[ -f "${SVG}" ]] || { printf 'missing %s\n' "${SVG}" >&2; exit 1; }

log "rendering $(basename "${SVG}") at 1024px"
swift "${ROOT}/scripts/svg2png.swift" "${SVG}" 1024 "${WORK}/master.png" >/dev/null

# A blank or flattened render would ship a square, white-cornered icon and no
# other step would notice, so check the pixels rather than trusting the export.
if ! CHECK="$(swift "${ROOT}/scripts/inspect-icon.swift" "${WORK}/master.png")"; then
    printf '%s\n' "${CHECK}" >&2
    printf 'icon render failed its structural check\n' >&2
    exit 1
fi

ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "${ICONSET}"

# Every size macOS asks for, including the @2x variants.
while read -r size name; do
    sips -z "${size}" "${size}" "${WORK}/master.png" --out "${ICONSET}/${name}.png" >/dev/null
done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
SIZES
cp "${WORK}/master.png" "${ICONSET}/icon_512x512@2x.png"

iconutil -c icns "${ICONSET}" -o "${OUT}"
log "wrote Resources/AppIcon.icns ($(stat -f%z "${OUT}") bytes)"
