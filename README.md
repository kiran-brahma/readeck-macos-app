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
Resources/NOTICE                  Readeck attribution + AGPL source offer
scripts/build.sh                  fetch -> verify -> assemble -> sign
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
├── engine-version       last engine that opened the database
├── logs/server.log      captured stdout, rotated at launch
├── backups/             pre-migration snapshots, last 3 kept
└── data/                db.sqlite3, bookmarks/, content-scripts/
```

## Upgrade

Engine version is pinned in `scripts/build.sh`. To move to a new release, update
`ENGINE_VERSION` and `ENGINE_SHA256`, then rebuild. A database snapshot is taken
automatically before the first `serve` that runs a new engine version, because
migrations run inside `serve` and two of them (M07, M16) rewrite the archive
`.zip` files on disk.

## Licensing

Readeck is AGPL-3.0-only. The bundled engine is redistributed unmodified, and
`Resources/NOTICE` carries the attribution and a link to the corresponding
source. The launcher is an independent program that starts the engine as a
separate process.
