# AGENTS.md

Leaf is a macOS menu-bar utility (Swift + SwiftUI) that watches running apps and
closes or notifies about ones that have been idle too long, while keeping
genuinely active apps alive.

## Commands

Use the `Makefile`:

- `make build` – Debug build
- `make run` – build and launch (does not install)
- `make test` – run the unit test suite
- `make release` / `make install` – Release build / copy to /Applications

Always run `make test` after changing tracking logic.

## Layout

- `Leaf/Tracker.swift` – core engine: tracks running apps, samples processes,
  decides notify/quit/keep-alive. Holds the testable pure logic.
- `Leaf/AudioActivityMonitor.swift` – Core Audio HAL wrapper; PIDs playing audio.
- `Leaf/MenuView.swift` – menu bar UI and per-app mode controls.
- `Leaf/SettingsView.swift` – settings window.
- `LeafTests/TrackerLogicTests.swift` – Swift Testing suite.

## Conventions

- **Keep decision logic pure and testable.** Put system-free logic in `static`
  functions on `Tracker` (e.g. `decideAction`, `isConsideredActive`,
  `resolveOwner`, `aggregateSignals`) and add tests in `TrackerLogicTests`.
  System access (NSWorkspace, Core Audio, `ps`) stays in instance methods.
- **No hardcoded app allow/blocklists.** Behavior must be general. The only
  intentional exception is attributing system `WebKit.framework` processes to
  Safari (`systemWebKitOwnerBundleID`); document any new exception.
- **Per-app modes** are the mutually-exclusive `AppMode` enum
  (`notify` / `protect` / `silentQuit` / `hide`), persisted under `appModes`. Preserve the
  legacy `nonNotifyApps` migration path.
- **Activity = foreground OR audio output OR CPU over threshold**, aggregated
  across an app's helper processes (mapped by bundle-path containment). Prefer
  keeping a busy app alive over closing one in use.
- The Xcode project uses synchronized file groups: new files under `Leaf/` are
  picked up automatically; no `project.pbxproj` editing needed to add sources.
- Comments explain intent/trade-offs, not what the code obviously does.

## Notes

- Deployment target macOS 14.6 (per-process audio APIs need 14.2+).
- Update `CHANGELOG.md` and bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
  for user-facing changes.
- Only commit when explicitly asked.
