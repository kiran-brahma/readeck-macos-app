# Readeck.app

A small native macOS launcher that runs a bundled, **unmodified** [Readeck](https://codeberg.org/readeck/readeck)
server as a child process and shows Readeck's own UI in a `WKWebView`.

Personal tool. One machine, one user. Not distributed, so there is no Sparkle,
no appcast, no notarization, no Developer ID, no CI, and no universal binary.
The design record is [`docs/decisions/readeck-macos-launcher-goldilocks.md`](docs/decisions/readeck-macos-launcher-goldilocks.md).

## Build

```sh
./scripts/build.sh          # -> dist/Readeck.app
open dist/Readeck.app
```

The script fetches the pinned upstream engine into `vendor/`, verifies it
against a hard-coded SHA-256, strips `com.apple.quarantine`, builds the Swift
launcher, assembles the bundle, and ad-hoc signs it.

`vendor/` is an integrity pin, not a convenience: if the checksum ever fails to
match, the script refuses to build. The engine is never patched.

## Verify

```sh
./scripts/verify.sh      # 35 checks, about two minutes
```

Every check maps to an invariant in the design record. They are end-to-end on
purpose: the failures worth catching are lifecycle ones — an orphaned engine, a
second writer on one database, a migration that ran before its backup — and none
of those are visible to a unit test.

It runs against a throwaway directory, so it never touches your real library.
Several checks are deliberately destructive (Force Quit, a faked engine upgrade,
an unwritable backups directory) because that is what makes them worth running.

The suite is launched directly, not via `open`, so the isolated directory reaches
the child — everything the app does is driven by paths it computes itself, so the
launch mechanism does not affect what is being tested.

Two notes:

- The port-blocked check briefly puts an alert on screen before killing it.
- `READECK_LAUNCHER_HOME` is a **test seam, not a feature**. It exists because
  Foundation derives the Application Support path from the password database
  rather than `$HOME`, so redirecting HOME does not isolate the app. If it is set
  in your shell, the app will use it instead of the real support directory.

## Tools menu

- **Back Up Now** (⇧⌘B) — a snapshot on demand. Safe while the server is running:
  SQLite reads consistently against a live writer.
- **Reveal Backups in Finder**, **Reveal Log**, **Open Data Folder**.

## Never commit

The repository must stay **code only**. Four things hold secrets or private
data, and all four are gitignored from the first commit:

| Path | What it contains |
|---|---|
| `config.toml` | the HKDF `secret_key`. Every Readeck token, session, and preference key is derived from it (`configs/keys.go`). Leak it and every issued token is forgeable. |
| `data/db.sqlite3` | your complete reading history |
| `data/bookmarks/*.zip` | every archived page, in plain form |
| `backups/` | a copy of the same, and `logs/server.log` holds every URL visited |

At runtime these live in `~/Library/Application Support/Readeck/`, not here. If
you later sync this repository to GitHub, sync **the repo** — never a folder
that happens to contain the data directory.

## Layout

```
Package.swift                     Swift Package (no .xcodeproj)
Sources/ReadeckApp/               the launcher
Resources/Info.plist              bundle metadata (incl. NSAllowsLocalNetworking)
Resources/logo-square.svg         Readeck's own artwork, unmodified
Resources/NOTICE                  Readeck attribution + AGPL source offer
scripts/build.sh                  fetch -> verify -> assemble -> sign
scripts/verify.sh                 end-to-end acceptance suite
scripts/build-icon.sh             SVG -> AppIcon.icns
scripts/svg2png.swift             SVG rasteriser (macOS reads SVG natively)
scripts/inspect-icon.swift        catches a blank or flattened icon render
vendor/                           pinned engine, gitignored
dist/                             built bundle, gitignored
```

## Bundle

```
Readeck.app/Contents/
├── Info.plist
├── MacOS/
│   ├── Readeck              the Swift launcher
│   └── readeck-server       upstream engine, byte-identical
└── Resources/NOTICE
```

## Runtime state

```
~/Library/Application Support/Readeck/
├── config.toml          written by Readeck; holds secret_key
├── engine-version       the engine that last opened the database
├── server.json          pid of an engine we started, while it runs
├── .launcher.lock       flock target, released by the kernel on exit
├── logs/server.log      engine stdout, rotated past 5 MB
├── backups/             pre-migration and manual snapshots, last 3 kept
└── data/                db.sqlite3, bookmarks/, content-scripts/
```

## Upgrade

Engine version is pinned in `scripts/build.sh`. To move to a new release, update
`ENGINE_VERSION` and `ENGINE_SHA256`, then rebuild. A snapshot is taken
automatically before the first `serve` that runs a new engine version, because
migrations run inside `serve` and two of them (M07, M16) rewrite the archive
`.zip` files on disk.

**If that snapshot cannot be written, the app refuses to start.** A failed backup
is not something to log and move past when the next step rewrites files in place.

## Licensing

Readeck is AGPL-3.0-only. The bundled engine is redistributed unmodified, and
`Resources/NOTICE` carries the attribution and a link to the corresponding
source. The launcher is an independent program that starts the engine as a
separate process.
