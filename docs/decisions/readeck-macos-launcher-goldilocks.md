# Goldilocks review — Readeck macOS launcher

**Status:** approved

**Slug:** `readeck-macos-launcher`

---

## Problem and constraints

A self-hosted Readeck server must be usable as an ordinary double-clickable macOS app on one machine, with no terminal, without forking Readeck.

What must be true:

- The Readeck executable stays **byte-identical to upstream**, verified by checksum. No fork, no patches, no vendored changes.
- Personal use, one machine, one user. Unsigned / ad-hoc signed is acceptable; the app is **not distributed**.
- All state lives under `~/Library/Application Support/Readeck/`.
- Readeck listens on **127.0.0.1:8000**. If that port is held by a foreign process, the app **closes** rather than relocating.
- The app owns the server's lifetime: no terminal, no manual `serve`.
- Upgrading the wrapper or the engine must never cost the user their account or their library.
- Environment: macOS 27, arm64, Xcode 27 / Swift 6.4, **no Developer ID certificate**.

What cannot change:

- Readeck's own startup contract (`serve` auto-runs migrations; `config.toml` is created in the working directory; the working directory must be writable).
- The browser extension must keep working against `http://127.0.0.1:8000/` with zero configuration.

### Evidence (verified, not assumed)

| Fact | Source |
|---|---|
| `readeck serve` traps SIGTERM/SIGINT, caps graceful shutdown at 5s, exits 0 | `internal/app/serve.go:270-292` |
| `signal.Notify` consumes **one** signal — a second SIGTERM is ignored | `internal/app/serve.go:106-108` |
| `config.toml` is created in the process **CWD**; unwritable CWD exits 1 before env vars apply | `internal/app/app.go:228-268` |
| Migrations run automatically inside `serve` | `internal/app/app.go:157-160`, `internal/db/storage.go:178-238` |
| M07 rewrites every archive `.zip` in place; M16 deletes and rebuilds `bookmarks/` | `internal/db/migrations/migrations.go:40-104`, `internal/db/migrations/16_uuid.go:178-230` |
| `/api/info` is unauthenticated and returns `{"version":{"canonical":"0.23.4",…}}` | `internal/server/server.go:66-74`; observed live |
| `/onboarding` is mounted only while zero users exist; first user is `admin`, auto-logged-in | `internal/auth/onboarding/http.go:22-39` |
| Logs — and even fatal `ERROR:` output — go to **stdout**, not stderr | `internal/app/app.go:88-119`, `main.go:16-20` |
| No CORS middleware; `AllowedHosts` is dead config; CSRF is bypassed for Bearer requests | full-tree grep of 0.23.4 |
| A downloaded unsigned Mach-O is SIGKILLed while `com.apple.quarantine` is set | observed: exit 137, zero output |
| Locally built + ad-hoc signed ⇒ no quarantine attribute ⇒ no Gatekeeper prompt | `codesign -dv` (adhoc, linker-signed); build script strips quarantine |

---

## Required complexity

Complexity the domain and environment impose. None of this can be removed, only relocated.

1. **Process lifecycle.** Readeck is a foreground HTTP server. Something must spawn it, await readiness, and terminate it — `SIGTERM`, wait, then `SIGKILL`, because the single-signal trap means a second polite signal does nothing.
2. **Exclusive access to one SQLite WAL database.** Two writers on one `db.sqlite3` risk corruption. **Nothing in Readeck enforces single-instance-per-data-directory.** The guarantee must come from the launcher.
3. **Destructive migrations.** M07 rewrites every archive in place; M16 deletes and rebuilds the archive tree. Data durability around upgrades is inherent, not optional.
4. **Writable CWD and config placement.** Readeck creates `config.toml` in its working directory and bails before applying configuration if it cannot. A Finder-launched app's default CWD is `/`.
5. **Gatekeeper / quarantine.** Unsigned downloaded executables are killed outright, with no dialog and no output.
6. **Web-only UI.** Readeck offers no native surface; its UI must be rendered as web content.

## Incidental complexity

Avoidable complexity. This review deletes rather than rearranges it.

| Deleted | Replaced by | Why it was incidental |
|---|---|---|
| `launcher.json` holding `{pid, port, startedAt, engineVersion}` | `flock` ownership bit + one `engine-version` string | PID files suffer reuse races and go stale; `startedAt` and `port` were never load-bearing |
| `proc_pidpath` check to prove a PID is *our* server | `flock` on the data directory | Proving identity by executable path is a workaround for not owning a lock |
| Alternate-port probing and port persistence | "8000 or close" | Port selection existed only to dodge conflicts the user chose to treat as fatal |
| Sparkle, appcast, notarization, Developer ID, hardened runtime, CI, `lipo`, `.dmg` pipeline | nothing | All distribution concerns; the app is not distributed |
| Auto-update machinery | rebuild via `scripts/build.sh` | One machine, one user, one operator |

---

## Candidates

### C1 — Bundled-engine launcher *(chosen)*

SwiftUI app; `readeck-server` sits in `Contents/MacOS/`; the app owns the child process, the data directory, logs, and pre-migration backups; `WKWebView` renders `http://127.0.0.1:8000/`.

- **Coupling:** app version and engine version move together. Launcher ↔ engine is a build-time coupling, not a runtime one.
- **Operational:** single artifact. Upgrade = re-run `scripts/build.sh`. Nothing installed outside the support directory.
- **State:** `flock` on the support directory (ownership) + one persisted engine-version string (migration detection). Both are single facts with obvious lifetimes.
- **Change cost:** engine bumps require rebuilding the app, even when the wrapper is untouched.

### C2 — External-engine supervisor

Same Swift app, but the engine lives at `~/Library/Application Support/Readeck/bin/readeck-<version>`; the app discovers versions and picks one.

- **Coupling:** app and engine decouple at runtime — the point of the shape.
- **Operational:** two install surfaces to keep coherent; a "no engine installed" first-run path; version discovery and ordering rules.
- **State:** adds an engine inventory that must be reconciled with the data directory.
- **Change cost:** engine bumps stop touching Swift, at the price of new moving parts.

### C3 — LaunchAgent daemon + thin viewer

The server runs at login as a `LaunchAgent`; the app is only a window onto it.

- **Coupling:** server lifetime moves out of the app into the OS session.
- **Operational:** an always-on background service on a laptop; a second install surface (`SMAppService`/plist) to manage.
- **State:** the app can no longer guarantee the server is stopped before a backup or an engine swap.
- **Change cost:** lowest for the extension's availability, highest for everything else.

### C4 — Smallest plausible: no launcher

A `.command` script starts `readeck serve` and reveals `http://127.0.0.1:8000/` in the browser (optionally added to the Dock as a web app).

- **Coupling:** none between app and engine; no Swift at all.
- **Operational:** trivial to write, and nothing to sign.
- **State:** no ownership discipline — the corruption guard in required-complexity #2 simply does not exist.
- **Change cost:** near zero, and it fails the stated goal. A `.command` flashes a terminal window; a browser tab is not an app; lifecycle, logs, and backups remain manual.

---

## Decision

**C1 — bundled-engine launcher**, with the incidental-complexity deletions above.

It is in the Goldilocks zone because it is the only candidate that satisfies every constraint simultaneously: one artifact, an unmodified engine, no background service, no terminal, and a real app identity. C4 is too small — it deletes the ownership guarantee that protects the library, which is required complexity. C2 and C3 are larger than the problem: both add runtime machinery whose only benefit is deferring a rebuild that costs one command.

The design is defensible from a short sequence, which is the real test:

```
acquire flock ─┬─ held elsewhere? → focus that instance, quit
               │
               └─ acquired → probe 8000
                    ├─ foreign  → alert, quit
                    ├─ readeck  → refuse: another library owns this port
                    └─ idle     → version changed? → snapshot DB
                                  → spawn serve (cwd + env + -config)
                                  → poll /api/info → show webview
```

Three invariants hold at all times:

- **I1 — single writer.** The app never spawns a server while any Readeck answers on 8000. Combined with the foreign-refusal rule, no two writers can share a data directory.
- **I2 — backup before migration.** A DB snapshot exists on disk before any `serve` invocation whose engine version differs from the last recorded one, since migrations run inside `serve`.
- **I3 — no orphans.** `SIGTERM`, bounded wait, `SIGKILL`. The lock file makes a surviving orphan visible to the next launch rather than invisible.

### The state model is explicit

`idle → owning | adopting → starting → ready → stopping → stopped | failed(reason)`

Every transition is driven by an observed fact, never by elapsed time. `ready` is entered only when `/api/info` returns Readeck JSON.

---

## Amendments

Corrections made during implementation, where evidence contradicted this review.

### A1 — `flock` does not replace the PID record

This review claimed `flock` plus one version string could replace `launcher.json`. That was wrong in one respect, and the deletion was partly undone.

`flock` proves that no other **launcher** is running. It says nothing about which data directory a listening server is using. So an engine orphaned by a Force Quit is indistinguishable, by lock alone, from a Readeck started elsewhere — and those need opposite responses: adopt one, refuse the other.

`ServerRecord` therefore returns, reduced to a single field: `{pid}`. Identity is confirmed by comparing `proc_pidpath(pid)` against the bundled engine's path, which also closes the PID-reuse hole the original `launcher.json` never addressed. The deletions that stood are `startedAt` and `port`, which really were never load-bearing.

### A2 — the engine's stdout is a file, not a pipe

This review did not specify how to capture stdout. A pipe is the obvious choice and is wrong here.

Measured: with a pipe, Force Quitting the launcher leaves an engine that stops answering HTTP immediately and is **dead within ~5 seconds**. The read end dies with the launcher, so the engine's next log write raises SIGPIPE — and Go deliberately lets SIGPIPE kill a program writing to a dead fd 1 or 2.

That is not a guarantee, it is an accident: an orphan self-destructs only if the engine happens to log, so an engine that stayed quiet would linger holding the database, and adoption could never be relied on. Redirecting stdout straight to the log file makes the behaviour deterministic and the log complete — output buffered in a pipe at crash time is otherwise lost, and this log is the only place Readeck reports a fatal error.

Consequence: after a Force Quit the engine **does** survive, and adoption is now a real, tested path rather than a theoretical one.

### A3 — a modal alert inside an async task waits for the user

Not a defect, recorded because it was misdiagnosed. `NSAlert.runModal()` called from a SwiftUI `.task` blocks until a button is pressed; it does not self-dismiss. An app that vanishes from a test harness is being dismissed by the person in front of it.

---

## Rejected alternatives

- **C2 (external engine)** — rejected as speculative flexibility. Its benefit (engine bumps without rebuilding Swift) addresses a cost that is one shell command, while its price is a version-discovery module and a first-run path for a state that should not exist. Revisit only if rebuilding the wrapper becomes the bottleneck.
- **C3 (LaunchAgent)** — rejected because it moves server lifetime outside the app, which breaks the ability to guarantee I2 (backup before migration) and I3 (clean stop), and puts an always-on service on a laptop.
- **C4 (no launcher)** — rejected because it deletes required complexity. Ownership discipline and pre-migration backup are what protect a library that M07/M16 can rewrite on disk; a shell script has neither.
- **PID-file ownership** (an earlier iteration of C1) — rejected in favour of `flock`. A lock file is released by the kernel on process death, so it cannot go stale, and it has no PID-reuse race.
- **Alternate-port fallback** — rejected by decision, not by analysis. It is technically fully supported (the extension has no hard-coded 8000), but it would hide conflicts instead of surfacing them.

---

## Interfaces and seams

Each module owns one thing and is allowed to know as little as possible.

| Module | Owns | Allowed to know | Must not know |
|---|---|---|---|
| `Paths` | Filesystem layout | Base directory only | Anything about servers or HTTP |
| `Ownership` | The `flock` handle | One data directory | Ports, versions, UI |
| `EngineProbe` | `GET /api/info` | A port | Data directory, UI, process handles |
| `ProbeResult` | — | `idle \| readeck(version) \| foreign(pid, name)` | — |
| `BundledEngine` | Path and `version` output | The bundle | The data directory |
| `ServerProcess` | The child process | Spawn arguments, stdout stream | Ownership, backups |
| `DatabaseSnapshot` | Snapshot + prune | SQLite file names, retention count | Anything about why a snapshot was needed |
| `LogSink` → `ServerLog` | The `server.log` file | The log path | Which lines matter |
| `LauncherModel` | The state machine | All of the above | Nothing — it is the composition root |
| `WebView`, views | Presentation | A URL and a state enum | Policy of any kind |

`LauncherModel` is the only module that knows ordering. Everything else is independently testable: `EngineProbe` against a Python stub, `Ownership` against two processes, `DatabaseSnapshot` against a fixture.

`DatabaseSnapshot` uses SQLite's own backup (`.backup` / `VACUUM INTO`) to produce one consistent restorable file without a running server, falling back to copying `db.sqlite3` + `-wal` + `-shm`. Its interface is deliberately narrow: it does not decide *when* to snapshot.

---

## Operational path

- **Deploy.** `scripts/build.sh`: fetch the pinned arm64 release → verify upstream `.sha256` → `xattr -c` (strip quarantine) → assemble `Readeck.app` → ad-hoc sign inner binary, then bundle. Open `Package.swift` in Xcode to debug.
- **Configure.** Zero user configuration. `config.toml` is created by Readeck inside the support directory; the launcher pins `-host 127.0.0.1 -port 8000`, sets `READECK_DATA_DIRECTORY`, and sets the child's CWD.
- **Observe.** Child stdout is appended to `logs/server.log`, rotated at launch, and tailed in-app. Failures surface as a sheet with the log tail plus Reveal Log — necessary because Readeck writes fatal errors to stdout, not stderr.
- **Recover.** Force Quit leaves an orphan; the next launch detects it on port 8000 and adopts it. A crash mid-session is reported, not silently retried.
- **Migrate.** Engine version change ⇒ snapshot after acquiring the lock and before spawning, satisfying I2. Retention: last 3.
- **Roll back.** Restore a snapshot file over `data/db.sqlite3` with the app quit, and reinstall the previous `Readeck.app`. Archives rely on Time Machine, which covers `~/Library/Application Support` by default.
- **Backup location.** Snapshots are plain files in one folder, `~/Library/Application Support/Readeck/backups/`, pruned to the last 3. Visibility comes from a *Reveal Backups in Finder* menu item rather than from relocating the folder, so pruning and Time Machine both keep operating on a single known path.
- **Repository hygiene — hard precondition for the planned GitHub sync.** The repository must never contain `data/`, `backups/`, `logs/`, or the fetched engine binary. `config.toml` holds the HKDF `secret_key`; `db.sqlite3` and the archive zips hold the entire library. Committing any of them would publish both the key that derives every Readeck token, session, and preference, and the user's complete reading history. All four are gitignored from the first commit, and `README.md` states it.

---

## Ticket boundaries

Each slice is independently verifiable; none is a layer.

1. **Build skeleton** — `Package.swift`, `build.sh` (fetch, verify, strip quarantine, assemble, sign). *Verifiable:* an ad-hoc signed `Readeck.app` whose bundled binary's hash matches upstream.
2. **Happy path** — spawn, poll `/api/info`, webview, launched from Finder. *Verifiable:* onboarding loads from a cold double-click.
3. **Shutdown** — `SIGTERM`/wait/`SIGKILL`; window close vs quit. *Verifiable:* no orphan after `⌘Q`, by `pgrep`.
4. **Ownership** — `flock`, foreign-refusal, adopt-our-orphan. *Verifiable:* `kill -9` then relaunch adopts; `python3 -m http.server 8000` causes an alert and exit.
5. **Durability** — engine-version detection, snapshot, prune. *Verifiable:* a snapshot exists before a version-changing spawn.
6. **Diagnostics** — stdout capture, rotation, failure sheet. *Verifiable:* an induced failure is explainable in-app.
7. **Back Up Now** — manual snapshot menu item.
8. **Verification suite + README** — the eight tests below, encoded.

### Acceptance tests

| # | Test | Passes when |
|---|---|---|
| 1 | Cold launch from Finder, no terminal | Onboarding loads (catches the CWD contract) |
| 2 | Create account, restart | Still logged in |
| 3 | `⌘Q` | Clean shutdown in the log; no orphan |
| 4 | `kill -9` app, relaunch | Adopts the orphan; exactly one server |
| 5 | Foreign process on 8000 | Alert names it, then quits |
| 6 | Bump engine to 0.24.x | Snapshot exists **before** spawn |
| 7 | Extension → `http://127.0.0.1:8000/` | Bookmark saves, zero config |
| 8 | `codesign -v`; `shasum -a 256` | Signature valid; hash matches upstream |

---

## Resolved questions

1. **Backend dies mid-session → fail loudly, with a Restart button.** Decided. No automatic restart: a crash loop against a migrating database is worse than a stopped app, and a silent restart hides the condition that caused it. The state machine therefore gains `failed(reason) → starting` as an explicit, user-initiated transition, and `failed` is a terminal state until the user acts.
2. **`Back Up Now` is in v1.** Decided. It is the manual counterpart to the automatic pre-migration snapshot, and the only user-accessible defence against the destructive migrations.
3. **Backups are plain files in a single known folder** — `~/Library/Application Support/Readeck/backups/`, pruned to the last 3, with a *Reveal Backups in Finder* menu item supplying visibility rather than relocating the folder. Decided: co-located, so path, pruning, and Time Machine scope all stay known.
4. **Adopt-if-ours confirmed.** `flock` held elsewhere → focus that instance and quit; a foreign process on 8000 → alert and quit.
5. **No `DESIGN.md`.** This document is the design record.

## Open questions

None blocking. Two implementation details to settle during their slices, neither of which changes the design:

- Whether `serve -port` overrides the port written into a freshly generated `config.toml` (we pin 8000 regardless).
- Whether `readeck export` produces a portable all-in-one archive (affects `Back Up Now`'s implementation, not its interface).

---

**Approved.** Ticket slices 1–8 in *Ticket boundaries* may be published.
