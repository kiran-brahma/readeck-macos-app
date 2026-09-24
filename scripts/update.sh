#!/usr/bin/env bash
#
# Updates the app on this machine.
#
# Rebuilds from source rather than downloading the released bundle. The engine
# is cached in vendor/, so a rebuild takes seconds, and a local build carries no
# com.apple.quarantine attribute -- which is the only thing that makes macOS
# refuse to open an ad-hoc signed app. Gatekeeper never prompts on this path.
#
# The released .app exists for rollback, and for people who do not have the repo.
#
# Usage: scripts/update.sh [--from-finder]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/versions.sh
source "${ROOT}/scripts/versions.sh"

APP_NAME="Readeck"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALLED="${INSTALL_DIR}/${APP_NAME}.app"
BUILT="${ROOT}/dist/${APP_NAME}.app"

from_finder=false
[[ "${1:-}" == "--from-finder" ]] && from_finder=true

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Double-clicked from Finder the window would otherwise vanish before the result
# is readable. A flag rather than a tty test, since both paths have a tty.
close_if_finder() {
    if [[ "${from_finder}" == true ]]; then
        printf '\nPress return to close this window. '
        read -r _ || true
    fi
}
trap close_if_finder EXIT

# --- 1. never replace an app that is running --------------------------------
if pgrep -f "${INSTALLED}/Contents/MacOS/${APP_NAME}$" >/dev/null 2>&1; then
    die "${APP_NAME} is running. Quit it, then run this again."
fi

# --- 2. newest source --------------------------------------------------------
if [[ -n "$(git -C "${ROOT}" status --porcelain)" ]]; then
    die "the repository has uncommitted changes; commit or stash them first"
fi

log "fetching"
git -C "${ROOT}" pull --ff-only

# --- 3. build whatever this checkout declares --------------------------------
log "building ${RELEASE_TAG}"
"${ROOT}/scripts/build.sh"

# --- 4. check what we are about to install -----------------------------------
actual="$(shasum -a 256 "${BUILT}/Contents/MacOS/readeck-server" | awk '{print $1}')"
[[ "${actual}" == "${ENGINE_SHA256}" ]] || die "the built engine does not match the pinned checksum"
codesign --verify --deep --strict "${BUILT}" || die "the built app failed signature verification"

# --- 5. install --------------------------------------------------------------
log "installing to ${INSTALLED}"
if [[ -e "${INSTALLED}" ]]; then
    rm -rf "${INSTALLED}" || die "could not remove the previous ${INSTALLED}"
fi
ditto "${BUILT}" "${INSTALLED}"

# --- 6. report ---------------------------------------------------------------
log "installed ${RELEASE_TAG}"

if ! git -C "${ROOT}" rev-parse -q --verify "refs/tags/${RELEASE_TAG}" >/dev/null; then
    warn "this checkout is not tagged ${RELEASE_TAG}: you are running unreleased source"
fi

if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
    warn "something is still listening on port 8000; the app will refuse to start until it is gone"
fi

log "open ${INSTALLED} when you want it"
