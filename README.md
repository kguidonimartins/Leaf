# Leaf App

A lightweight **macOS menu bar productivity utility** that helps you automatically manage inactive applications.  

Built with **Swift**, **SwiftUI**, and **Xcode**, Leaf App improves focus and system performance by monitoring app activity in the background and closing unused apps based on user-defined preferences.

## 📌 Requirements

- macOS 14.6 or later (per-process audio APIs need 14.2+)
- Xcode 26+ (for building from source — required by the SwiftUI Liquid
  Glass APIs, e.g. `.glass`, used in onboarding)

## ↓ Download & Installation

This is a fork of [Satwik](https://satwiktungala.com)'s original [Leaf](https://github.com/Atswik/Leaf). It has no
compiled releases of its own yet and auto-update is disabled (see below), so
for now, build it from source — see "Building from source" below.

## ⚡️ Features

- **Per-app memory threshold** – With Smart Alerts on, an inactive app in
  `notify` mode is eligible for a warning once it and its helper processes
  together use at least 200 MB RSS. `silentQuit` and `hide` act on idle time
  regardless of memory use. This is a fixed per-app limit, not a read of the
  system's overall memory pressure.
- **Safe Quit** – Sends standard native termination requests (`Cmd + Q`) rather than force-killing processes, ensuring target apps still prompt you to save unsaved work.
- **Zero Data Collection** – 100% local processing with absolutely no telemetry or tracking.
- **Optimized Performance** – Background service designed to use minimal memory and CPU.
- **Optimized for Apple Silicon** – Lightweight background footprint designed specifically for modern Mac architectures.
- **Custom Inactivity Timer** – Configure how long apps can stay idle before being flagged.
- **Four per-app modes** – `notify` (ask before quitting), `protect` (never
  touch), `silentQuit` (quit with no prompt), and `hide` (hide instead of
  quitting) — set per app from the menu bar.
- **Background activity detection** – An app playing audio or busy on the
  CPU (including its helper processes, e.g. browser/Electron helpers) is
  kept alive even while idle.

## 🧱 Building from source

With Xcode installed, the included `Makefile` wraps the common commands:

```bash
make build     # compile a Debug build
make run       # build and launch the app (does not install)
make install   # build Release and copy to /Applications
make test      # run the unit test suite
make release   # compile a Release build
make clean     # clean build artifacts
```

You can also open `Leaf.xcodeproj` in Xcode and build/run with ⌘R.

## ⚙️ Configuration

Settings and per-app modes are persisted to `~/.config/leaf/config.toml`
(hand-editable; changes are picked up live) and mirrored to `UserDefaults`.
It's created on first launch from your existing UserDefaults values.
For `launch_at_login`, a change made in macOS Login Items takes precedence
over an unchanged TOML value. Change that value explicitly, or use the
Settings switch, to request a new login item state.

```toml
version = 1

[general]
launch_at_login = false
quit_without_notify = false
notify_after_minutes = 15       # one of 5, 10, 15, 30, 60, 120, 240
smart_alerts = true             # memory filter, applies to notify only
keep_active_apps_alive = true   # background activity detection

# Per-app modes: notify | protect | silent_quit | hide
[apps]
"com.apple.Safari" = "protect"
```

Malformed files, unknown section headers, and files missing `version = 1`
are ignored; current settings are kept. Use an empty `[apps]` section to
intentionally clear every app mode.

## 🛠️ Tech Stack

- **Language:** Swift  
- **UI Framework:** SwiftUI  
- **IDE:** Xcode  
- **APIs:** NSWorkspace, NSRunningApplication  
- **Storage:** `~/.config/leaf/config.toml` + `UserDefaults`
- **Updates:** Sparkle 2, currently disabled in this fork (see below)

## 📬 Contact

Leaf was originally created by [Satwik](https://satwiktungala.com); this
fork tracks their upstream at [Atswik/Leaf](https://github.com/Atswik/Leaf).
Auto-update is disabled here since this fork has no signing key for
upstream's feed and no feed of its own — see `CHANGELOG.md`.

For issues or feature ideas specific to this fork, open an issue on this
repository.
