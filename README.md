# Readeck.app

A small macOS launcher that runs upstream's Readeck engine as a child process and
shows Readeck's own UI in a `WKWebView`.

Built for one Mac and one user, then published so others can run the same thing.
There is no Sparkle, no appcast, no notarization, no Developer ID, no CI, and no
universal binary. [Requirements](#requirements) covers what that costs in
practice.

Latest release: <https://github.com/kiran-brahma/readeck-macos-app/releases/latest>

The design record is
[`docs/decisions/readeck-macos-launcher-goldilocks.md`](docs/decisions/readeck-macos-launcher-goldilocks.md).
It explains why closing the window keeps the server running, why the engine is
never patched, and why an in-app updater is deliberately absent.

## Requirements

- macOS 14 or later.
- Apple silicon (arm64). There is no Intel build, because the engine is pinned to
  upstream's `darwin/arm64` artifact and nothing is built with `lipo`.
- Xcode, for `swift`, `codesign`, `sips`, `iconutil`, and `ditto`. The Swift
  toolchain alone is not enough, because the icon is rendered by a small Swift
  program and packed with `iconutil`.
- About 500 MB of disk for the first build: 62 MB for the engine, 335 MB of Swift
  build output, and 115 MB for the bundle and its zip. Check with
  `du -sh vendor .build dist`.

The package has no third-party Swift dependencies, and the build needs no
Homebrew. The icon is rasterised with macOS's own SVG support instead of
`librsvg`.

## Build from source

```sh
git clone https://github.com/kiran-brahma/readeck-macos-app.git
cd readeck-macos-app
./scripts/build.sh
open dist/Readeck.app
```

`scripts/build.sh` does the whole build:

1. Downloads the pinned engine into `vendor/`. This is 65 MB and happens once.
2. Verifies it against upstream's published SHA-256.
3. Strips `com.apple.quarantine`.
4. Builds the launcher with `swift build -c release`.
5. Renders the app icon from Readeck's own `logo-square.svg`.
6. Assembles `dist/Readeck.app`.
7. Ad-hoc signs it.

Later builds take seconds, because the engine is already in `vendor/`.

### Build a specific release

```sh
git checkout 0.23.4-1
./scripts/build.sh
```

The tag is the Readeck engine version, so the app version and the engine version
always match. A fix to the launcher alone takes a revision suffix, as in
`0.23.4-1`.

## Install or update from source

```sh
./scripts/update.sh
```

`update.sh` rebuilds the current checkout and installs it to
`/Applications/Readeck.app`. Run the same command later to update. In Finder you
can double-click **Update Readeck.command** instead.

It refuses to run if the working tree has uncommitted changes or if the app is
already running. It checks the built engine against the pinned checksum and
verifies the signature before it replaces anything. Set `INSTALL_DIR` to install
somewhere else.

This path never prompts Gatekeeper, because it never downloads anything. A build
made on your own Mac carries no `com.apple.quarantine` attribute, and that
attribute is the only thing that makes macOS refuse an ad-hoc signed app.

## Install from a release

Set `tag` to the release you want. The
[releases page](https://github.com/kiran-brahma/readeck-macos-app/releases) lists
them.

Download with `gh` or `curl`, not a browser.

```sh
tag=0.23.4-1
gh release download "$tag" --repo kiran-brahma/readeck-macos-app -D ~/Downloads
(cd ~/Downloads && shasum -a 256 -c "Readeck-$tag-macos-arm64.zip.sha256")
ditto -x -k ~/Downloads/"Readeck-$tag-macos-arm64.zip" /Applications
```

Without `gh`:

```sh
tag=0.23.4-1
base=https://github.com/kiran-brahma/readeck-macos-app/releases/download/$tag
curl -L -O "$base/Readeck-$tag-macos-arm64.zip"
curl -L -O "$base/Readeck-$tag-macos-arm64.zip.sha256"
shasum -a 256 -c "Readeck-$tag-macos-arm64.zip.sha256"
ditto -x -k "Readeck-$tag-macos-arm64.zip" /Applications
```

`gh` and `curl` do not set `com.apple.quarantine`. Browsers do. If you download in
a browser, macOS refuses the first launch. Open **System Settings → Privacy &
Security** and click **Open Anyway** for Readeck. You need to do that once per
download, not once per launch.

Use `ditto -x -k` rather than `unzip` to extract the archive. `unzip` also works,
but it leaves a `__MACOSX` folder behind in `/Applications`.

## Verify

```sh
./scripts/verify.sh
```

35 checks, about two minutes. Every check maps to an invariant in the design
record.

The suite runs against a throwaway directory, so it never touches your real
library. Some checks are deliberately destructive: they force-quit the app, fake
an engine upgrade, and make the backups directory unwritable.

Two notes:

- The port-blocked check puts an alert on screen briefly before killing it.
- `READECK_LAUNCHER_HOME` is a test seam, not a feature. Foundation derives the
  Application Support path from the password database rather than `$HOME`, so
  redirecting HOME does not isolate the app. If you set this variable in your
  shell, the app uses it instead of the real support directory.

## Release

```sh
./scripts/release.sh --dry-run   # runs the gate, packages, prints the notes
./scripts/release.sh             # tags, pushes, publishes
```

The tag matches Readeck's own tag exactly, with no `v` prefix. For a launcher-only
fix with no engine change, set `RELEASE_REVISION` in `scripts/versions.sh` to
produce `0.23.4-1`.

`release.sh` refuses to run on a dirty tree, refuses an existing tag both locally
and on the remote, and refuses unless `verify.sh` reports 35/35. There is no
override. If the suite is failing, fixing it is the work.

Each release carries the built `.app` as a zip plus a `.sha256`. The zip needs
`--sequesterRsrc`, because one made without it extracts to an app whose signature
is invalid.

The build runs locally rather than in CI, because the acceptance suite drives
`NSApplication` and `WKWebView` and needs a real GUI session.

## Tools menu

- **Back Up Now** (⇧⌘B) takes a snapshot on demand. It is safe while the server is
  running, because SQLite reads consistently against a live writer.
- **Reveal Backups in Finder** opens the backups folder.
- **Reveal Log** opens `logs/server.log`.
- **Open Data Folder** opens the data directory.
- **Show Readeck Window** (⌘1) reopens the window after you close it.

## Never commit

The repository must stay code only. Four things hold secrets or private data, and
all four are gitignored from the first commit:

| Path | What it contains |
|---|---|
| `config.toml` | the HKDF `secret_key`. Readeck derives every token, session, and preference key from it (`configs/keys.go`), so a leak makes every issued token forgeable. |
| `data/db.sqlite3` | your complete reading history |
| `data/bookmarks/*.zip` | every archived page, in plain form |
| `backups/` | a copy of the same. `logs/server.log` holds every URL you visited. |

At runtime these live in `~/Library/Application Support/Readeck/`, not here. When
you sync this repository to GitHub, sync the repository. Never sync a folder that
happens to contain the data directory.

## Repository layout

```
Package.swift                     Swift Package, no .xcodeproj
Sources/ReadeckApp/               the launcher
Resources/Info.plist              bundle metadata, incl. NSAllowsLocalNetworking
Resources/logo-square.svg         Readeck's own artwork, unmodified
Resources/NOTICE                  Readeck attribution and AGPL source offer
scripts/build.sh                  fetch, verify, assemble, sign
scripts/versions.sh               single source of truth for versions
scripts/update.sh                 rebuild and install to /Applications
scripts/release.sh                gate, package, tag, push, publish
scripts/verify.sh                 end-to-end acceptance suite
scripts/build-icon.sh             SVG to AppIcon.icns
scripts/svg2png.swift             SVG rasteriser
scripts/inspect-icon.swift        catches a blank or flattened icon render
Update Readeck.command            double-clickable wrapper for update.sh
vendor/                           pinned engine, gitignored
dist/                             built bundle, gitignored
```

## Bundle contents

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
├── config.toml          written by Readeck, holds secret_key
├── engine-version       the engine that last opened the database
├── server.json          pid of an engine we started, while it runs
├── .launcher.lock       flock target, released by the kernel on exit
├── logs/server.log      engine stdout, rotated past 5 MB
├── backups/             pre-migration and manual snapshots, last 3 kept
└── data/                db.sqlite3, bookmarks, content-scripts
```

## Upgrade

Engine version and its checksum live in `scripts/versions.sh`, which `build.sh`,
`verify.sh`, `update.sh`, and `release.sh` all source. To move to a new release,
update `ENGINE_VERSION` and `ENGINE_SHA256` there and rebuild, or run
`update.sh`.

The app takes a snapshot automatically before the first `serve` that runs a new
engine version, because migrations run inside `serve` and two of them (M07 and
M16) rewrite the archive `.zip` files on disk.

If that snapshot cannot be written, the app refuses to start. A failed backup is
not something to log and move past when the next step rewrites files in place.

## Licensing

Readeck is AGPL-3.0-only. The bundled engine is redistributed unmodified, and
`Resources/NOTICE` carries the attribution and a link to the corresponding
source. The launcher is an independent program that starts the engine as a
separate process.

`vendor/` is a checksum pin, not a convenience. If the checksum does not match
upstream's published one, the build fails instead of bundling something else.
That is what keeps this a thin launcher rather than a fork.
