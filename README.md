<div align="center">

# agenc-lid

**Keep your Mac awake while the lid is closed — for unattended agents, builds, and long-running jobs.**

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white)](https://swift.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/tetsuo-ai/agenc-lid?color=F97316)](https://github.com/tetsuo-ai/agenc-lid/releases/latest)

</div>

`agenc-lid` is a tiny native macOS menu bar app that flips macOS's `pmset` lid-sleep override on and off, so your Mac keeps running with the lid closed.

It is designed for short, supervised sessions — finishing a build, leaving an autonomous agent working, draining a long task — without putting the laptop to sleep when you fold it shut.

---

## Features

- **One-click lid-awake toggle** from the menu bar — no Terminal, no plist edits.
- **Timed sessions:** 1 hour, 4 hours, or until-reset.
- **Live status panel** showing the current power source, battery percentage, system sleep timer, and display sleep timer.
- **Native AppKit UI** with a dark, brand-consistent panel (no Electron, no web view).
- **Lightweight:** ~400 KB binary, idle CPU = 0%, no background daemons.
- **Privacy-respecting:** stores no password, makes no network calls, ships no analytics.

## Requirements

- macOS 13 (Ventura) or newer
- Apple Silicon or Intel

## Install

### Option 1 — Pre-built `.dmg` (recommended)

1. Download the latest `agenc-lid-x.y.z.dmg` from [Releases](https://github.com/tetsuo-ai/agenc-lid/releases/latest).
2. Open the DMG and drag **agenc-lid** to **Applications**.
3. Launch it once from `/Applications` (right-click → Open the first time, since the build is ad-hoc signed).

> The app icon does not appear in the Dock — look for the AGENC mark in the top-right menu bar.

### Option 2 — Homebrew

```sh
brew tap tetsuo-ai/agenc-lid https://github.com/tetsuo-ai/agenc-lid
brew install --cask agenc-lid
```

### Option 3 — Build from source

```sh
git clone https://github.com/tetsuo-ai/agenc-lid.git
cd agenc-lid
./build.sh
open build/agenc-lid.app
```

The build script needs:

- Xcode command-line tools (`xcode-select --install`)
- `librsvg` for icon generation: `brew install librsvg`

## Usage

Click the **AGENC** mark in the menu bar to open the control panel.

| State | What you see | What it does |
|-------|--------------|--------------|
| **OFF** | `1 HOUR` · `4 HOURS` · `UNTIL RESET` | Lid sleep follows normal macOS behavior. |
| **ON** | `ACTIVE SESSION` · `TURN OFF` | macOS will not sleep when the lid is closed. |

- **1 HOUR / 4 HOURS** flips `pmset -a disablesleep 1`, then automatically flips it back after the timer expires (even if the app crashes — the timer is a detached `nohup` shell job).
- **UNTIL RESET** keeps lid sleep disabled until you click **TURN OFF** or quit the app.
- **DETAILS** opens a panel with raw `pmset -g` values and a **Copy raw pmset** button for sharing diagnostics.

### Safety notes

- `disablesleep 1` is **system-wide** — it affects more than just lid-close behavior.
- **Do not put a closed MacBook in a bag or tight sleeve while `agenc-lid` is armed.** Heat needs somewhere to go.
- Prefer the timed actions for unattended work, so the override automatically lifts.
- Use **Reset sleep** when you are done.

## How it works

The app shells out to `/usr/bin/pmset` via a privileged helper invocation:

```
/usr/bin/pmset -a disablesleep 1   # enable
/usr/bin/pmset -a disablesleep 0   # disable
```

For timed sessions it spawns a detached `nohup` job that:

1. Writes a session token to `/var/tmp/com.agenc.lid.timer-token`.
2. Sleeps for the requested duration.
3. Confirms the token still matches (so a manual disable wins) and flips `disablesleep` back to `0`.

Privilege elevation uses `osascript … with administrator privileges`. **No password is stored** — macOS handles authentication and caches it for the session.

A future hardening step replaces the AppleScript prompt with a signed privileged helper installed via `ServiceManagement`.

## Architecture

```
Sources/agenc-lid/main.swift   # Entire app — single Swift file, no dependencies
Resources/
  AppIcon.svg                   # Dock / Finder icon (rendered to .icns at build time)
  BrandMark.svg                 # AGENC mark used in alert dialogs
  MenuBarIconOn.svg             # Status bar icon — armed (green)
  MenuBarIconOff.svg            # Status bar icon — idle (white)
  Info.plist                    # LSUIElement = true (menu bar agent app)
build.sh                        # rsvg-convert + swiftc + iconutil + codesign
```

The full build pipeline runs in under five seconds on Apple Silicon.

## Development

```sh
# Build & run
./build.sh && open build/agenc-lid.app

# Live debug — show the popover automatically on launch
AGENC_LID_SHOW_PANEL=1 ./build/agenc-lid.app/Contents/MacOS/agenc-lid

# Force ON / OFF / Details preview without changing system state
AGENC_LID_SHOW_PANEL=1 AGENC_LID_PREVIEW_STATE=on  ./build/agenc-lid.app/Contents/MacOS/agenc-lid
AGENC_LID_SHOW_PANEL=1 AGENC_LID_PREVIEW_STATE=off ./build/agenc-lid.app/Contents/MacOS/agenc-lid
AGENC_LID_SHOW_PANEL=1 AGENC_LID_PREVIEW_VIEW=details ./build/agenc-lid.app/Contents/MacOS/agenc-lid
```

## Releases

Tag a release to trigger an automated DMG build:

```sh
git tag v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

The [release workflow](.github/workflows/release.yml) builds, packages, and attaches the DMG to a draft GitHub Release.

## Contributing

Issues and PRs welcome. Keep the binary single-file and dependency-free.

Before opening a PR:

```sh
./build.sh
open build/agenc-lid.app   # smoke-test the panel + DETAILS view
```

## License

[GPL-3.0](LICENSE)
