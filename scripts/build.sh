#!/usr/bin/env bash
#
# Builds Readeck.app.
#
#   1. fetch the pinned upstream engine    (cached in vendor/, gitignored)
#   2. verify its SHA-256 against the pin  (integrity gate)
#   3. strip com.apple.quarantine          (or Gatekeeper SIGKILLs it silently)
#   4. build the Swift launcher
#   5. assemble the bundle
#   6. ad-hoc sign                         (no Developer ID, no notarization)
#
# The engine is never patched. It is redistributed byte-identical to upstream,
# and this script fails loudly if that stops being true.

set -euo pipefail

ENGINE_VERSION="0.23.4"
ENGINE_ARCH="arm64"
ENGINE_SHA256="1c9f58b8d63a682c3a7ca2a6c6c267d5e2fbe31b47c606e21adc2195417b64d9"

APP_NAME="Readeck"
BUNDLE_ID="dev.kiranbrahma.readeck"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_FILE="readeck-${ENGINE_VERSION}-macos-${ENGINE_ARCH}"
ENGINE_URL="https://codeberg.org/readeck/readeck/releases/download/${ENGINE_VERSION}/${ENGINE_FILE}"
VENDOR="${ROOT}/vendor"
APP="${ROOT}/dist/${APP_NAME}.app"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- 1. fetch ---------------------------------------------------------------
mkdir -p "${VENDOR}"
if [[ ! -f "${VENDOR}/${ENGINE_FILE}" ]]; then
    log "fetching ${ENGINE_FILE}"
    tmp="$(mktemp "${VENDOR}/.download.XXXXXX")"
    curl -fL --proto '=https' --tlsv1.2 -o "${tmp}" "${ENGINE_URL}" \
        || die "download failed: ${ENGINE_URL}"
    mv "${tmp}" "${VENDOR}/${ENGINE_FILE}"
fi

# --- 2. verify --------------------------------------------------------------
log "verifying engine checksum"
actual="$(sha "${VENDOR}/${ENGINE_FILE}")"
if [[ "${actual}" != "${ENGINE_SHA256}" ]]; then
    die "engine checksum mismatch
       expected ${ENGINE_SHA256}
       actual   ${actual}
  Refusing to bundle a modified engine."
fi

# --- 3. strip quarantine ----------------------------------------------------
# A downloaded unsigned Mach-O carrying com.apple.quarantine is killed by
# Gatekeeper with no dialog and no output (observed exit status 137).
xattr -c "${VENDOR}/${ENGINE_FILE}" 2>/dev/null || true

# --- 4. build the launcher --------------------------------------------------
log "building launcher (release)"
swift build -c release --package-path "${ROOT}"
BIN_DIR="$(swift build -c release --package-path "${ROOT}" --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"
[[ -x "${BIN}" ]] || die "launcher binary not found: ${BIN}"

# --- 5. icon ----------------------------------------------------------------
# Derived from upstream artwork, so the icon is regenerated whenever the source
# SVG changes. Only the SVG is committed; the .icns is a build artifact.
if [[ ! -f "${ROOT}/Resources/AppIcon.icns" || "${ROOT}/Resources/logo-square.svg" -nt "${ROOT}/Resources/AppIcon.icns" ]]; then
    log "building app icon from upstream artwork"
    "${ROOT}/scripts/build-icon.sh"
fi

# --- 6. assemble the bundle -------------------------------------------------
log "assembling ${APP_NAME}.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${VENDOR}/${ENGINE_FILE}" "${APP}/Contents/MacOS/readeck-server"
chmod +x "${APP}/Contents/MacOS/${APP_NAME}" "${APP}/Contents/MacOS/readeck-server"
xattr -c "${APP}/Contents/MacOS/readeck-server" 2>/dev/null || true

sed -e "s|@VERSION@|${ENGINE_VERSION}|g" \
    -e "s|@BUNDLE_ID@|${BUNDLE_ID}|g" \
    "${ROOT}/Resources/Info.plist" > "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
cp "${ROOT}/Resources/NOTICE" "${APP}/Contents/Resources/NOTICE"

if [[ -f "${ROOT}/Resources/AppIcon.icns" ]]; then
    cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi

# --- 7. sign ----------------------------------------------------------------
# Ad-hoc only. Built locally and ad-hoc signed means no quarantine attribute is
# ever set, so there is no Gatekeeper prompt and no trip to System Settings.
log "signing (ad-hoc)"
codesign --force --sign - --timestamp=none "${APP}"

# --- verify -----------------------------------------------------------------
log "verifying signature"
if ! codesign --verify --deep --strict --verbose=2 "${APP}" 2>&1 | sed 's/^/    /'; then
    die "signature verification failed"
fi

bundled_sha="$(sha "${APP}/Contents/MacOS/readeck-server")"
if [[ "${bundled_sha}" != "${ENGINE_SHA256}" ]]; then
    die "bundled engine is not byte-identical to upstream
       expected ${ENGINE_SHA256}
       actual   ${bundled_sha}"
fi

log "engine byte-identical to upstream"
"${APP}/Contents/MacOS/readeck-server" version
log "built ${APP}"
