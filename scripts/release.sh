#!/usr/bin/env bash
#
# Cuts a release: gate, build, package, tag, push, publish.
#
# Local by design. The acceptance suite drives NSApplication and WKWebView and
# needs a real GUI session, so it cannot run on a CI runner -- and CI would be a
# second place where "the build" is defined, for a repository with one user.
#
# The tag is the engine version, matching Readeck's own tag exactly. A
# launcher-only fix takes a revision suffix from scripts/versions.sh.
#
# Usage: scripts/release.sh [--dry-run]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/versions.sh
source "${ROOT}/scripts/versions.sh"

APP_NAME="Readeck"
BUILT="${ROOT}/dist/${APP_NAME}.app"
ARTIFACT_BASE="${APP_NAME}-${RELEASE_TAG}-macos-${ENGINE_ARCH}"
ZIP="${ROOT}/dist/${ARTIFACT_BASE}.zip"
CHECKSUM="${ZIP}.sha256"
NOTES="$(mktemp)"
trap 'rm -f "${NOTES}"' EXIT

dry_run=false
[[ "${1:-}" == "--dry-run" ]] && dry_run=true

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. the tree must be exactly what gets tagged ----------------------------
if [[ -n "$(git -C "${ROOT}" status --porcelain)" ]]; then
    die "the working tree has uncommitted changes; a release must be reproducible from its tag"
fi

branch="$(git -C "${ROOT}" branch --show-current)"
[[ "${branch}" == "main" ]] || log "note: on branch ${branch}, not main"

# --- 2. the tag must be new --------------------------------------------------
if git -C "${ROOT}" rev-parse -q --verify "refs/tags/${RELEASE_TAG}" >/dev/null; then
    die "tag ${RELEASE_TAG} already exists locally"
fi
if git -C "${ROOT}" ls-remote --tags origin "refs/tags/${RELEASE_TAG}" 2>/dev/null | grep -q .; then
    die "tag ${RELEASE_TAG} already exists on origin"
fi

# --- 3. the gate -------------------------------------------------------------
# No override. If the suite is failing, fixing it is the work.
log "running the acceptance suite (this is the release gate)"
"${ROOT}/scripts/verify.sh" || die "the acceptance suite failed; not releasing"

# --- 4. build and package ----------------------------------------------------
log "building"
"${ROOT}/scripts/build.sh"

log "packaging"
rm -f "${ZIP}" "${CHECKSUM}"
ditto -c -k --sequesterRsrc --keepParent "${BUILT}" "${ZIP}"
zip_sha="$(shasum -a 256 "${ZIP}" | awk '{print $1}')"
printf '%s  %s\n' "${zip_sha}" "$(basename "${ZIP}")" > "${CHECKSUM}"

# --- 5. notes ----------------------------------------------------------------
previous="$(git -C "${ROOT}" describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -n "${previous}" ]]; then
    changes="$(git -C "${ROOT}" log --pretty='- %s' "${previous}..HEAD")"
else
    changes="$(git -C "${ROOT}" log --pretty='- %s')"
fi
[[ -n "${changes}" ]] || changes="- No launcher changes; engine update only."

cat > "${NOTES}" <<NOTES_EOF
Readeck.app **${RELEASE_TAG}** — the macOS launcher for Readeck **${ENGINE_VERSION}**.

Runs a bundled, unmodified Readeck server on \`127.0.0.1:8000\` and shows
Readeck's own UI. Data lives in \`~/Library/Application Support/Readeck/\`.

## Requirements and restrictions

- **Apple silicon (arm64) only.** There is no Intel build.
- **macOS 14 or later.**
- **Ad-hoc signed, not notarized.** There is no Developer ID behind this, so
  there is no notarization and no in-app updater.
- Readeck itself is **AGPL-3.0-only**. The bundled engine is redistributed
  byte-identical to upstream, verified against upstream's own published
  checksum. Its corresponding source is
  https://codeberg.org/readeck/readeck/tree/${ENGINE_VERSION} and the app ships
  \`Contents/Resources/NOTICE\` with the attribution.

## Install

**Download it from a terminal, not a browser.** \`gh\` and \`curl\` do not set
\`com.apple.quarantine\`; browsers do, and a quarantined ad-hoc signed app is
refused by macOS on first launch.

    gh release download ${RELEASE_TAG} --pattern '*.zip' -D ~/Downloads
    unzip ~/Downloads/${ARTIFACT_BASE}.zip -d /Applications

Or, without \`gh\`:

    curl -L -o ~/Downloads/${ARTIFACT_BASE}.zip \\
      https://github.com/kiran-brahma/readeck-macos-app/releases/download/${RELEASE_TAG}/${ARTIFACT_BASE}.zip
    unzip ~/Downloads/${ARTIFACT_BASE}.zip -d /Applications

**If you did download it in a browser**, macOS will refuse the first launch.
Open **System Settings → Privacy & Security** and click **Open Anyway** for
Readeck. That is required once per download, not once per launch.

## Integrity

    ${zip_sha}  ${ARTIFACT_BASE}.zip

Verify with \`shasum -a 256 -c ${ARTIFACT_BASE}.zip.sha256\`. The engine inside
is additionally checked against upstream's published checksum at build time; if
it does not match, the build refuses to run.

## Changes

${changes}
NOTES_EOF

if [[ "${dry_run}" == true ]]; then
    log "dry run: nothing was tagged, pushed or published"
    log "would tag ${RELEASE_TAG}, push ${branch} and the tag, and publish:"
    printf '  %s\n  %s\n' "$(basename "${ZIP}")" "$(basename "${CHECKSUM}")"
    printf '\n----- release notes -----\n\n'
    cat "${NOTES}"
    exit 0
fi

# --- 6. tag, push, publish ---------------------------------------------------
log "tagging ${RELEASE_TAG}"
git -C "${ROOT}" tag -a "${RELEASE_TAG}" -m "Version ${RELEASE_TAG}"

log "pushing ${branch} and ${RELEASE_TAG}"
git -C "${ROOT}" push origin "${branch}"
git -C "${ROOT}" push origin "refs/tags/${RELEASE_TAG}"

log "publishing"
gh release create "${RELEASE_TAG}" \
    --title "Version ${RELEASE_TAG}" \
    --notes-file "${NOTES}" \
    --verify-tag \
    "${ZIP}" "${CHECKSUM}"

log "released ${RELEASE_TAG}"
