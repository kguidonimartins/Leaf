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

    @Test func resolvedConfigURLFollowsRelativeSymlinkToItsTarget() throws {
        let fixture = try makeSymlinkedFixture(initialTargetContent: "")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        #expect(fixture.manager.resolvedConfigURL().standardizedFileURL == fixture.targetURL.standardizedFileURL)
    }
}
