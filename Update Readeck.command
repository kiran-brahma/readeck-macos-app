#!/usr/bin/env bash
#
# Double-click this in Finder to update Readeck.
#
# Finder runs .command files in Terminal, which is the whole point: no typing.
# See scripts/update.sh for what it actually does and why it never trips
# Gatekeeper.

cd "$(dirname "$0")" || exit 1
exec ./scripts/update.sh --from-finder
