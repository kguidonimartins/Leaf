import Foundation
import Testing
@testable import Leaf

/// Exercises ConfigManagerImpl's real file I/O against a scratch directory
/// with `config.toml` as a relative symlink — the exact layout that broke
/// saving on a real machine (see AUDITORIA task 1). Everything here uses an
/// injected `configURL` and a disposable `UserDefaults` suite, so it never
/// touches the real `~/.config/leaf` or the shared `com.satwik.Leaf` domain.
struct ConfigManagerIOTests {

    /// Sets up `<tmp>/config/config.toml` as a relative symlink to
    /// `<tmp>/target/real.toml`, returning both URLs plus a disposable
    /// UserDefaults suite. Callers get a fresh temp directory removed by the
    /// test framework's process cleanup (not shared, so no teardown needed
    /// beyond the UserDefaults suite).
    private func makeSymlinkedFixture(initialTargetContent: String) throws -> (
        manager: ConfigManagerImpl,
        symlinkURL: URL,
        targetURL: URL,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-io-tests-\(UUID().uuidString)")
        let configDir = base.appendingPathComponent("config")
        let targetDir = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let targetURL = targetDir.appendingPathComponent("real.toml")
        try initialTargetContent.write(to: targetURL, atomically: true, encoding: .utf8)

        let symlinkURL = configDir.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "../target/real.toml")

        let suiteName = "com.leaf.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let manager = ConfigManagerImpl(configURL: symlinkURL, defaults: defaults)
        return (manager, symlinkURL, targetURL, defaults, suiteName)
    }

    @Test func saveWritesThroughSymlinkPreservingLinkAndBackingUpPreviousContent() throws {
        let fixture = try makeSymlinkedFixture(initialTargetContent: "version = 1\n# stale content\n")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let tracker = Tracker()
        tracker.appModes = ["com.example.SymlinkTest": .protect]
        fixture.manager.configure(tracker: tracker)

        fixture.manager.saveToDisk()

        // The symlink itself must still be a symlink, pointing at the same
        // relative target — not replaced by a plain file.
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.symlinkURL.path)
        #expect(destination == "../target/real.toml")

        // The resolved target received the new content.
        let targetContent = try String(contentsOf: fixture.targetURL, encoding: .utf8)
        #expect(targetContent.contains("\"com.example.SymlinkTest\" = \"protect\""))

        // The backup is a regular file (not a copy of the link) holding the
        // content that was in the target before this save.
        let backupURL = fixture.targetURL.deletingLastPathComponent().appendingPathComponent("config.toml.bak")
        #expect(throws: Error.self) {
            _ = try FileManager.default.destinationOfSymbolicLink(atPath: backupURL.path)
        }
        let backupContent = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(backupContent == "version = 1\n# stale content\n")
    }

    @Test func loadResolvesSymlinkAndAppliesTargetContent() throws {
        let toml = """
            version = 1

            [general]
            launch_at_login = true

            [apps]
            "com.example.Loaded" = "hide"
            """
        let fixture = try makeSymlinkedFixture(initialTargetContent: toml)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let tracker = Tracker()
        fixture.manager.configure(tracker: tracker)

        fixture.manager.loadFromDiskOrMigrate()

        #expect(fixture.defaults.bool(forKey: "launchAtLogin") == true)
        #expect(tracker.appModes["com.example.Loaded"] == .hide)
    }

    @Test func loadingInvalidContentThroughSymlinkLeavesCurrentStateUntouched() throws {
        // A typo'd header with no version: exactly the shape that used to
        // silently wipe every app mode on load.
        let fixture = try makeSymlinkedFixture(initialTargetContent: """
            [aps]
            "com.example.Wiped" = "protect"
            """)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.defaults.set(true, forKey: "launchAtLogin")
        let tracker = Tracker()
        tracker.appModes = ["com.example.Keep": .protect]
        fixture.manager.configure(tracker: tracker)

        fixture.manager.loadFromDiskOrMigrate()

        // Nothing from the invalid file should have been applied: the
        // pre-existing UserDefaults value and tracker state are untouched.
        #expect(fixture.defaults.bool(forKey: "launchAtLogin") == true)
        #expect(tracker.appModes == ["com.example.Keep": .protect])
    }

    @Test(arguments: [
        "version = 1\n[apps]\n\"com.example.Keep\" = \"protect",
        "version = 1\n[aps]\n\"com.example.Keep\" = \"protect\"",
        "version = 1\n[general]\nsmart_alerts = perhaps\n[apps]",
        "version = 1\n[apps]\n\"com.example.Keep\" = \"unknown\"",
        "version = 1\n[apps]\n\"com.example.Keep\" = \"protect\"\n\"com.example.Keep\" = \"hide\"",
    ])
    func malformedFileKeepsModesAndDiskContent(_ content: String) throws {
        let fixture = try makeSymlinkedFixture(initialTargetContent: content)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let tracker = Tracker()
        tracker.appModes = ["com.example.Keep": .protect]
        fixture.manager.configure(tracker: tracker)

        fixture.manager.loadFromDiskOrMigrate()

        #expect(tracker.appModes == ["com.example.Keep": .protect])
        #expect(try String(contentsOf: fixture.targetURL, encoding: .utf8) == content)
    }

    @Test func emptyAppsSectionClearsModesOnLoad() throws {
        let fixture = try makeSymlinkedFixture(initialTargetContent: "version = 1\n[apps]\n")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let tracker = Tracker()
        tracker.appModes = ["com.example.Keep": .protect]
        fixture.manager.configure(tracker: tracker)

        fixture.manager.loadFromDiskOrMigrate()

        #expect(tracker.appModes.isEmpty)
    }

    @Test func acceptedExternalEditInvalidatesPendingDefaultsSave() throws {
        let initial = "version = 1\n[general]\nnotify_after_minutes = 30\n[apps]\n"
        let external = "version = 1\n[general]\nnotify_after_minutes = 120\n[apps]\n"
        let fixture = try makeSymlinkedFixture(initialTargetContent: initial)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.manager.loadFromDiskOrMigrate()

        fixture.defaults.set(60, forKey: "closingTime")
        fixture.manager.scheduleSaveForTesting()
        try external.write(to: fixture.targetURL, atomically: true, encoding: .utf8)
        fixture.manager.loadFromDiskOrMigrate()
        fixture.manager.flushPendingSaveForTesting()

        #expect(fixture.defaults.integer(forKey: "closingTime") == 120)
        #expect(try String(contentsOf: fixture.targetURL, encoding: .utf8) == external)
    }

    @Test func laterDefaultsEditCanSaveAfterExternalReload() throws {
        let initial = "version = 1\n[general]\nnotify_after_minutes = 30\n[apps]\n"
        let external = "version = 1\n[general]\nnotify_after_minutes = 120\n[apps]\n"
        let fixture = try makeSymlinkedFixture(initialTargetContent: initial)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.manager.loadFromDiskOrMigrate()
        try external.write(to: fixture.targetURL, atomically: true, encoding: .utf8)
        fixture.manager.loadFromDiskOrMigrate()

        fixture.defaults.set(60, forKey: "closingTime")
        fixture.manager.scheduleSaveForTesting()
        fixture.manager.flushPendingSaveForTesting()

        #expect(fixture.defaults.integer(forKey: "closingTime") == 60)
        #expect(try String(contentsOf: fixture.targetURL, encoding: .utf8).contains("notify_after_minutes = 60"))
    }

    @Test func firstLaunchCreatesConfigAndReopensWithMigratedValues() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("leaf-migrate-\(UUID().uuidString)")
        let configURL = base.appendingPathComponent("config/config.toml")
        let suiteName = "com.leaf.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(60, forKey: "closingTime")
        defaults.set(false, forKey: "smartAlerts")
        let tracker = Tracker()
        tracker.appModes = ["com.example.Keep": .protect]
        let manager = ConfigManagerImpl(configURL: configURL, defaults: defaults)
        manager.configure(tracker: tracker)

        manager.loadFromDiskOrMigrate()
        manager.flushPendingSaveForTesting()

        let content = try String(contentsOf: configURL, encoding: .utf8)
        #expect(ConfigManagerImpl.validate(content) == nil)
        #expect(content.contains("notify_after_minutes = 60"))
        #expect(content.contains("\"com.example.Keep\" = \"protect\""))

        defaults.set(15, forKey: "closingTime")
        let reopenedTracker = Tracker()
        let reopened = ConfigManagerImpl(configURL: configURL, defaults: defaults)
        reopened.configure(tracker: reopenedTracker)
        reopened.loadFromDiskOrMigrate()
        #expect(defaults.integer(forKey: "closingTime") == 60)
        #expect(reopenedTracker.appModes["com.example.Keep"] == .protect)
    }

    @Test func migrationCreatesMissingSymlinkTarget() throws {
        let fixture = try makeSymlinkedFixture(initialTargetContent: "")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try FileManager.default.removeItem(at: fixture.targetURL)
        let tracker = Tracker()
        tracker.appModes = ["com.example.Keep": .protect]
        fixture.manager.configure(tracker: tracker)

        fixture.manager.loadFromDiskOrMigrate()
        fixture.manager.flushPendingSaveForTesting()

        let content = try String(contentsOf: fixture.targetURL, encoding: .utf8)
        #expect(ConfigManagerImpl.validate(content) == nil)
        #expect(content.contains("\"com.example.Keep\" = \"protect\""))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.symlinkURL.path) == "../target/real.toml")
    }

    @Test func resolvedConfigURLFollowsRelativeSymlinkToItsTarget() throws {
        let fixture = try makeSymlinkedFixture(initialTargetContent: "")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        #expect(fixture.manager.resolvedConfigURL().standardizedFileURL == fixture.targetURL.standardizedFileURL)
    }
}
