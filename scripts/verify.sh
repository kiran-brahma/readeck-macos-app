#!/usr/bin/env bash
#
# Acceptance suite for Readeck.app.
#
# Every check here maps to an invariant in
# docs/decisions/readeck-macos-launcher-goldilocks.md. They are end-to-end on
# purpose: the interesting failures are lifecycle ones — an orphaned engine, a
# second writer on one database, a migration that ran before its backup — and
# none of those are visible to a unit test.
#
# Runs against a throwaway READECK_LAUNCHER_HOME, so it never touches the real
# library. Several checks deliberately kill processes and fake an engine
# upgrade; that is the point.
#
# One visible side effect: the port-blocked check briefly puts an alert on
# screen before it is killed. Nothing else draws UI.
#
# Usage: scripts/verify.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/versions.sh
source "${ROOT}/scripts/versions.sh"
APP="${ROOT}/dist/Readeck.app"
BIN="${APP}/Contents/MacOS/Readeck"
PORT=8000
ENGINE_PATTERN="Contents/MacOS/readeck-server serve"

pass=0
fail=0

chk() {
    if eval "$2" >/dev/null 2>&1; then
        printf '  \033[1;32mPASS\033[0m  %s\n' "$1"
        pass=$((pass + 1))
    else
        printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"
        fail=$((fail + 1))
    fi
}

section() { printf '\n\033[1;34m==\033[0m %s\n' "$1"; }

if [[ ! -x "${BIN}" ]]; then
    printf 'error: %s not found. Run scripts/build.sh first.\n' "${BIN}" >&2
    exit 2
fi

if lsof -nP -iTCP:${PORT} -sTCP:LISTEN >/dev/null 2>&1; then
    printf 'error: port %s is already in use. Quit any running Readeck first.\n' "${PORT}" >&2
    exit 2
fi

WORK="$(mktemp -d)"
SUPPORT="${WORK}/Readeck"
LOG="${SUPPORT}/logs/server.log"
BACKUPS="${SUPPORT}/backups"
launcher_pid=""

cleanup() {
    [[ -n "${launcher_pid}" ]] && kill -9 "${launcher_pid}" 2>/dev/null
    pkill -f "${SUPPORT}" 2>/dev/null      # the engine, by its isolated -config path
    chmod -R u+w "${WORK}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

# Launched directly rather than via `open`, so the isolated home reaches the
# child. Everything the app does is driven by paths it computes itself, so the
# launch mechanism does not affect what is being tested.
launch() {
    READECK_LAUNCHER_HOME="${SUPPORT}" "${BIN}" >"${WORK}/launcher.log" 2>&1 &
    launcher_pid=$!
    # Without this, bash prints "Killed: 9" for every deliberate kill below.
    disown "${launcher_pid}" 2>/dev/null
}

engine_pids() { pgrep -f "${ENGINE_PATTERN}" | tr '\n' ' '; }
engine_count() { pgrep -f "${ENGINE_PATTERN}" | wc -l | tr -d ' '; }
stop_all() {
    kill -9 "${launcher_pid}" 2>/dev/null
    pkill -f "${SUPPORT}" 2>/dev/null
    sleep 2
}

printf '\nReadeck.app verification\nisolated home: %s\n' "${SUPPORT}"

# ---------------------------------------------------------------------------
section 'A. cold start'
launch
sleep 13
engine="$(engine_pids)"
chk "engine spawned"                  "test -n '${engine// /}'"
chk "engine args correct"             "pgrep -f 'readeck-server serve -config ${SUPPORT}/config.toml -host 127.0.0.1 -port ${PORT}'"
chk "server.json records the pid"     "grep -q $(echo ${engine} | awk '{print $1}') '${SUPPORT}/server.json'"
chk "/api/info answers"               "curl -s --max-time 3 http://127.0.0.1:${PORT}/api/info | grep -q '${ENGINE_VERSION}'"
chk "webview loaded Readeck's UI"     "grep -q '\"path\":\"/onboarding\"' '${LOG}'"
chk "config.toml has absolute paths"  "grep -q 'data_directory = \"${SUPPORT}/data\"' '${SUPPORT}/config.toml'"
chk "lock file created"               "test -f '${SUPPORT}/.launcher.lock'"
chk "no snapshot on a normal start"   "test \$(ls -1 '${BACKUPS}' 2>/dev/null | wc -l | tr -d ' ') = 0"

# ---------------------------------------------------------------------------
section 'B. Force Quit leaves the engine running (stdout is a file, not a pipe)'
kill -9 "${launcher_pid}"; launcher_pid=""
sleep 8
chk "engine survived the launcher"    "kill -0 $(echo ${engine} | awk '{print $1}')"
chk "engine still serving"            "curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT}/api/info | grep -q 200"
chk "log still growing after death"   "test \$(stat -f%z '${LOG}') -gt 0"

# ---------------------------------------------------------------------------
section 'C. relaunch adopts the orphan instead of starting a second engine'
launch
sleep 13
chk "exactly one engine"              "test \$(engine_count) = 1"
chk "same pid adopted, not respawned" "test \"\$(engine_pids)\" = \"${engine}\""

# ---------------------------------------------------------------------------
section 'D. a second instance does not spawn a second engine'
READECK_LAUNCHER_HOME="${SUPPORT}" "${BIN}" >/dev/null 2>&1 &
disown 2>/dev/null
sleep 6
chk "still one launcher"              "test \$(pgrep -f '${BIN}' | wc -l | tr -d ' ') = 1"
chk "still one engine"                "test \$(engine_count) = 1"

# ---------------------------------------------------------------------------
section 'E. clean quit'
osascript -e 'tell application "Readeck" to quit' 2>/dev/null &
sleep 6
chk "no orphaned engine"              "test \$(engine_count) = 0"
chk "port released"                   "! lsof -nP -iTCP:${PORT} -sTCP:LISTEN"
chk "server.json cleared"             "! test -f '${SUPPORT}/server.json'"
chk "graceful shutdown logged"        "grep -q 'workers stopped' '${LOG}'"

# ---------------------------------------------------------------------------
section 'F. an engine upgrade snapshots before migrations run'
launch; sleep 12; stop_all
echo "0.0.0" > "${SUPPORT}/engine-version"
launch
sleep 14
chk "engine started"                  "test \$(engine_count) = 1"
chk "a snapshot was taken"            "ls -1 '${BACKUPS}'/db-before-${ENGINE_VERSION}*.sqlite3 >/dev/null 2>&1"
snapshot="$(ls -t "${BACKUPS}"/db-before-${ENGINE_VERSION}*.sqlite3 2>/dev/null | head -1)"
chk "snapshot has no sidecars"        "test \$(ls '${snapshot}'-* 2>/dev/null | wc -l | tr -d ' ') = 0"
chk "snapshot journal mode is delete" "test \"\$(sqlite3 '${snapshot}' 'PRAGMA journal_mode;')\" = delete"
chk "snapshot passes integrity check" "test \"\$(sqlite3 '${snapshot}' 'PRAGMA integrity_check;')\" = ok"
chk "snapshot carries the schema"     "test \$(sqlite3 '${snapshot}' '.tables' | wc -w | tr -d ' ') -ge 10"
chk "version record updated"          "test \"\$(cat '${SUPPORT}/engine-version')\" = ${ENGINE_VERSION}"

# ---------------------------------------------------------------------------
section 'G. an unusable backup directory blocks the upgrade entirely'
stop_all
for i in 1 2 3 4 5; do echo x > "${BACKUPS}/db-fake-${i}.sqlite3"; done
echo "0.0.0" > "${SUPPORT}/engine-version"
chmod 500 "${BACKUPS}"
launch
sleep 10
chk "no engine started"               "test \$(engine_count) = 0"
chk "nothing was migrated"            "test \"\$(cat '${SUPPORT}/engine-version')\" = 0.0.0"
chk "launcher is showing the failure" "pgrep -f '${BIN}'"
chmod 700 "${BACKUPS}"
stop_all

# ---------------------------------------------------------------------------
section 'H. a foreign process on the port is refused'
python3 -m http.server ${PORT} >/dev/null 2>&1 &
python_pid=$!
disown "${python_pid}" 2>/dev/null
sleep 2
launch; sleep 6
chk "no engine spawned"               "test \$(engine_count) = 0"
kill "${python_pid}" 2>/dev/null
stop_all
chk "port released"                   "! lsof -nP -iTCP:${PORT} -sTCP:LISTEN"

# ---------------------------------------------------------------------------
section 'I. packaged artifact integrity'
expected="${ENGINE_SHA256}"
actual="$(shasum -a 256 "${APP}/Contents/MacOS/readeck-server" | awk '{print $1}')"
chk "engine is byte-identical to upstream" "test '${actual}' = '${expected}'"
chk "bundle signature is valid"       "codesign --verify --deep --strict '${APP}'"
chk "no quarantine attribute"         "! xattr -r '${APP}' | grep -qi quarantine"
chk "bundle id is set"                "test \"\$(plutil -extract CFBundleIdentifier raw '${APP}/Contents/Info.plist')\" = dev.kiranbrahma.readeck"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
