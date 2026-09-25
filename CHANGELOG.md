# Changelog

All notable changes to Leaf are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4] - Unreleased

This release adds a TOML configuration file for persistent settings, with
live-reload so hand-edited config is picked up automatically.

### Added

#### TOML configuration file
- **`~/.config/leaf/config.toml`** persists all GUI settings (launch at login,
  quit without notify, idle timeout, smart alerts, background activity detection,
  and per-app modes) in an editable TOML file.
- **Bidirectional sync with live-reload.** Changes made in the GUI are written
  back to the file; edits made by hand to `config.toml` are detected and applied
  to the running app within seconds.
- **Custom TOML parser/serializer** with no external dependencies. Pure functions
  for parse/serialize are unit-tested with round-trip, malformed-input, and
  migration coverage.
- **Migration from existing UserDefaults.** On first launch after the update, an
  existing user's settings are preserved by generating the TOML file from their
  current UserDefaults values.

### Changed
- **Version** bumped from 1.3 (build 5) to **1.4 (build 6)**, then to
  **1.4 (build 7)** for the config.toml symlink fix below, then to
  **1.4 (build 8)** for disabling Sparkle, then to **1.4 (build 9)** for the
  Smart Alerts scope fix below, then to **1.4 (build 10)** for the login
  item fix below.
- **The login item was re-registered/unregistered on every config load**,
  not just when the setting actually changed — including on every TOML
  edit and every app launch — which could revert a login item the user
  removed by hand in System Settings › Login Items, and logged a silent
  error when unregistering an app that was never registered. The logic
  (previously duplicated between `ConfigManagerImpl` and `SettingsView`) is
  now in one place and only calls `SMAppService.mainApp.register()`/
  `unregister()` when the desired state actually disagrees with
  `SMAppService.mainApp.status`. Settings also now reads that real status
  when it opens, instead of trusting the stored UserDefaults value, which
  could otherwise show "on" after the user turned it off outside Leaf.
- **Smart Alerts now only gates `notify`.** The memory filter previously
  applied to `silentQuit` and `hide` too, contradicting the Settings caption
  ("Only warns you about inactive apps with high memory usage"): an app in
  `silentQuit` or `hide` below the 200 MB threshold was never touched no
  matter how long it sat idle. Those two modes now act on idle time alone;
  only `notify` is filtered by memory usage.
- **Sparkle auto-update is disabled in this fork.** This repository still
  ships with the upstream author's `SUFeedURL`/`SUPublicEDKey` and bundle ID
  (`com.satwik.Leaf`); starting the updater against that feed would offer
  the original author's builds as "updates" and could silently overwrite
  this fork's binary, config, and per-app settings the moment upstream
  cuts a release with a higher version. `SPUStandardUpdaterController` is
  now started with `startingUpdater: false` (plus `SUEnableAutomaticChecks
  = NO` in Info.plist as a second guard), and the "Check for Updates"
  button is removed from Settings. The Sparkle integration itself is left
  in place, unused, for a future feed/key of this fork's own.

### Fixed
- **`config.toml` as a symlink (e.g. into a dotfiles repo) silently broke
  saving.** Writes replaced the link itself instead of updating its target,
  which failed outright, made `config.toml.bak` a copy of the link (so it
  protected nothing), and meant every launch re-applied the stale on-disk
  TOML over the user's real settings. Saves and reloads now resolve the
  symlink first and read/write through to the real target, preserving the
  link; the backup is a real file with the previous content. The live-reload
  watcher also now watches the resolved target file directly (not just its
  containing directory), so in-place edits from an editor that doesn't
  rename-on-save are picked up too.
- **`make test` mutated the real, shared UserDefaults domain and could
  schedule a real config.toml write.** The suite runs hosted inside the
  actual Leaf.app bundle ID; constructing the app's `Tracker` alone was
  enough to touch `UserDefaults.standard`. Test-hosting paths are now
  skipped behind a `XCTestConfigurationFilePath` check, and `make build` no
  longer runs the suite as a side effect of `make test` being a dependency.

## [1.3]

This release teaches Leaf to recognize when an app is genuinely busy in the
background (a call, a video, a build) and leave it alone, replaces the old
"notify / don't notify" switch with three explicit per-app modes, and adds a
unit-test suite plus build tooling.

### Added

#### Hide mode
- **New per-app mode: `hide`.** When inactive, the app is hidden (Cmd-H) instead
  of quit or notified about. This is useful for apps you want off your screen but
  still running (e.g. chat apps, background tools). The mode is mutually exclusive
  with `protect`, `silentQuit`, and `notify`, and is toggled via a new 👁 eye icon
  (`eye` / `eye.fill`, blue when active) in the menu bar list.
- **`hideApp(appID:)`** instance method on `Tracker` that calls
  `NSRunningApplication.hide()`. After hiding, the app's idle timer is reset so
  it isn't re-hidden immediately.
- **3 new unit tests** covering the hide decision: action when idle exceeded and
  memory consuming, ignored when not memory consuming, and ignored below the idle
  threshold.

#### Background activity detection
- **Keep active apps alive.** Apps that are doing real work in the background are
  no longer treated as idle. An app is considered active when any of the
  following is true:
  - it is the foreground app (unchanged), or
  - it (or one of its helper processes) is **playing audio output**, or
  - its processes together exceed a **CPU usage threshold** (7%).
  When active, the app's idle timer is reset every cycle, so it is never quit or
  notified about while in use.
- **Helper-process attribution.** Browsers and Electron apps do their real work
  in helper processes (e.g. `Google Chrome Helper`, `com.apple.WebKit.WebContent`),
  not in the main process. Leaf now maps each system process back to the owning
  app by checking whether the process executable lives inside that app's bundle,
  then aggregates audio (logical OR) and CPU (sum) per owning app. This works for
  Chrome, Microsoft Teams, Discord, and other Chromium/Electron apps without any
  hardcoded app list.
- **System WebKit (Safari) handling.** Safari's engine runs in shared system
  processes under `/System/Library/Frameworks/WebKit.framework/` that have no
  public link back to the Safari instance that spawned them. As the single,
  intentional exception to the otherwise list-free attribution, activity from
  `WebKit.framework` processes is attributed to Safari (`com.apple.Safari`) when
  Safari is running.
- **`AudioActivityMonitor`** (`Leaf/AudioActivityMonitor.swift`): a thin wrapper
  over the Core Audio HAL that reports the set of PIDs currently producing audio
  **output**, via `kAudioHardwarePropertyProcessObjectList` plus
  `kAudioProcessPropertyIsRunningOutput` / `kAudioProcessPropertyPID`. It filters
  out Leaf's own PID and returns an empty set on any failure (graceful
  degradation to the CPU/foreground signals). Microphone input is intentionally
  not used, so a meeting where the user only listens (no mic) still counts as
  active. The provider is defined behind an `AudioActivityProviding` protocol so
  it can be injected/mocked in tests.
- **"Keep active apps alive" toggle** in Settings (default: on). When disabled,
  Leaf reverts to its previous behavior where only the foreground app counts as
  active, and the extra audio query / path resolution work is skipped.

#### Per-app modes
- **Four explicit, mutually-exclusive per-app modes** replacing the old binary
  "notify / don't notify" flag:
  - `notify` (default): an idle app triggers a notification with a Quit action.
  - `protect`: the app is never touched.
  - `silentQuit`: the app is terminated when idle, with no notification.
  - `hide`: the app is hidden when idle.
- **Menu bar controls** for the new modes in `MenuView`:
  - a shield icon (`shield` / `shield.fill`, green when on) to protect an app,
  - a bolt icon (`bolt` / `bolt.fill`, orange when on) to silently quit an app,
  - tooltips ("Never close this app", "Quit this app without notifying").
- **Legacy migration**: existing `nonNotifyApps` boolean preferences are migrated
  into the new model (`true` → `protect`, `false` → `notify`), and the new state
  is persisted under the `appModes` key. The legacy storage is left intact for a
  safe rollback.

#### Tests and tooling
- **Unit-test suite** (`LeafTests/TrackerLogicTests.swift`) using Swift Testing,
  plus a `LeafTests` unit-test target wired into the Xcode project. Coverage
  includes:
  - legacy mode migration,
  - default mode selection,
  - the idle decision (`decideAction`) across modes / idle / memory states,
  - mode-toggle exclusivity,
  - the activity decision (`isConsideredActive`), including the "audio only,
    no foreground" case,
  - background-activity attribution (`resolveOwner` / `aggregateSignals`):
    helper-inside-bundle matching, longest-prefix for nested bundles, rejecting
    sibling bundles that share a path prefix, the WebKit→Safari fallback, and
    per-owner CPU summing / audio OR-ing.
- **`Makefile`** wrapping common commands: `build`, `run`, `install`, `test`,
  `release`, `clean`, `resolve`.
- **README**: new "Building from source" section documenting the `Makefile`
  targets.

### Changed
- **Process sampling** now collects CPU in addition to memory
  (`ps -e -o pid=,rss=,%cpu=`) and resolves each process' executable path via
  `proc_pidpath`, exposed as `ProcessSample` values. The previous
  memory-only `getMemoryUsageMap()` was replaced by `getProcessSamples(...)`.
- **The idle-timer reset loop** in `trackAndTerminate()` now uses the aggregated
  per-app activity signals (foreground / audio / CPU) instead of only checking
  the foreground app.
- **Removed the hardcoded media-player list.** Media players are no longer
  special-cased into `protect`; new apps simply follow the global "Quit without
  notifying" preference. Playing audio keeps a media player alive through the new
  activity detection, and a paused/idle one becomes eligible like any other app.
- **Settings layout** reworked for consistency: a single fixed-width controls
  column so every switch lines up, captions left-aligned beneath their toggle and
  wrapping to multiple lines, and a shared `toggleSetting(...)` helper for the
  toggle+caption rows. The window was resized to fit the additional content.
- **Version** bumped from 1.2 (build 3) to **1.3 (build 4)**.

### Fixed
- **Active background apps were being quit/notified.** Chrome, Microsoft Teams,
  and Safari could be terminated or flagged while actively playing audio or
  during a call, because their activity happens in helper processes that were not
  attributed to the owning app (Leaf only matched the main process PID). Activity
  is now aggregated across an app's helper processes, so these apps stay alive
  while in use. Verified live with Chrome and Safari playing video in the
  background (both detected as active and kept alive).
- **Settings captions were truncated** with an ellipsis on a single line; they
  now wrap to multiple lines (`fixedSize(horizontal: false, vertical: true)`).

### Notes / known limitations
- CPU usage is read from `ps` (`%cpu`), which on macOS is a recent decaying
  average. The 7% threshold is deliberately conservative, biased toward keeping a
  busy app alive rather than risking closing one in use.
- Because the WebKit engine is shared, audio/CPU from a `WKWebView` hosted by a
  different app is attributed to Safari (when Safari is running), not to that host
  app. Safari is by far the dominant source of WebKit audio, so this is an
  accepted trade-off.
- Per-process audio attribution via the Core Audio HAL can be affected by audio
  routing tools (e.g. Rogue Amoeba SoundSource/ARK). In that case the audio
  signal may be unavailable, but the summed-CPU fallback still keeps active apps
  (including Safari, via its WebKit processes) alive.
- Requires macOS 14.6+ (the project's deployment target); the per-process audio
  APIs need macOS 14.2+.

## [1.2]

- Improved functionality and handled edge cases.

## [1.0]

- Initial public release.
