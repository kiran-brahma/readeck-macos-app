#!/usr/bin/env bash
#
# Single source of truth for what this app is built from.
#
# Sourced by build.sh, verify.sh, update.sh and release.sh so the version has
# exactly one home. Side-effect free: it only assigns variables.

# The Readeck engine this app bundles. The app's release tag is this same
# version, matching upstream's tag exactly (no "v" prefix).
ENGINE_VERSION="0.23.4"
ENGINE_ARCH="arm64"

# Upstream's published checksum for that release. The build refuses to bundle
# anything else: the engine is never patched, and this pin is what proves it.
ENGINE_SHA256="1c9f58b8d63a682c3a7ca2a6c6c267d5e2fbe31b47c606e21adc2195417b64d9"

# Bumped only for a launcher-only fix with no engine change, producing
# 0.23.4-1, 0.23.4-2, ... so a release tag can never collide with an upstream
# engine tag. Empty for a normal release.
RELEASE_REVISION="1"

# Derived.
ENGINE_FILE="readeck-${ENGINE_VERSION}-macos-${ENGINE_ARCH}"
ENGINE_URL="https://codeberg.org/readeck/readeck/releases/download/${ENGINE_VERSION}/${ENGINE_FILE}"

if [[ -n "${RELEASE_REVISION}" ]]; then
    RELEASE_TAG="${ENGINE_VERSION}-${RELEASE_REVISION}"
else
    RELEASE_TAG="${ENGINE_VERSION}"
fi
