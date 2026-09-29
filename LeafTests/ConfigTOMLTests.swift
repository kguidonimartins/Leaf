import Foundation
import Testing
@testable import Leaf

struct ConfigTOMLTests {

    // MARK: - Parse / serialize round-trip

    @Test func roundTripParsesWhatItSerializes() {
        var config = LeafConfig()
        config.launchAtLogin = true
        config.quitWithoutNotify = true
        config.notifyAfterMinutes = 30
        config.smartAlerts = false
        config.keepActiveAppsAlive = false
        config.appModes = [
            "com.example.App": .protect,
            "com.other.App": .silentQuit,
            "com.hidden.App": .hide,
        ]

        let toml = ConfigManagerImpl.serialize(config)
        let parsed = ConfigManagerImpl.parse(toml)

        #expect(parsed.launchAtLogin == true)
        #expect(parsed.quitWithoutNotify == true)
        #expect(parsed.notifyAfterMinutes == 30)
        #expect(parsed.smartAlerts == false)
        #expect(parsed.keepActiveAppsAlive == false)
        #expect(parsed.appModes["com.example.App"] == .protect)
        #expect(parsed.appModes["com.other.App"] == .silentQuit)
        #expect(parsed.appModes["com.hidden.App"] == .hide)
    }

    @Test func roundTripDefaultConfigIsIdentity() {
        let config = LeafConfig()
        let toml = ConfigManagerImpl.serialize(config)
        let parsed = ConfigManagerImpl.parse(toml)
        #expect(parsed == config)
    }

    // MARK: - Parse: missing keys fall back to defaults

    // `parse` stays the permissive, always-succeeds low-level parser (used
    // for round-tripping and by callers that already validated the
    // content); `validate`/`parseValidated` below are the gate that
    // load/reload actually use.
    @Test func parseEmptyStringYieldsDefaults() {
        let parsed = ConfigManagerImpl.parse("")
        #expect(parsed == LeafConfig())
    }

    @Test func parseMissingKeysDefaultsArePreserved() {
        let toml = """
            [general]
            launch_at_login = true
            """
        let parsed = ConfigManagerImpl.parse(toml)
        #expect(parsed.launchAtLogin == true)
        #expect(parsed.quitWithoutNotify == false)
        #expect(parsed.notifyAfterMinutes == 15)
        #expect(parsed.smartAlerts == true)
        #expect(parsed.keepActiveAppsAlive == true)
        #expect(parsed.appModes.isEmpty)
    }

    // MARK: - Parse: unknown keys / unknown sections are ignored

    @Test func parseUnknownKeysIgnored() {
        let toml = """
            [general]
            launch_at_login = true
            unknown_key = 42

            [bogus]
            something = "else"
            """
        let parsed = ConfigManagerImpl.parse(toml)
        #expect(parsed.launchAtLogin == true)
    }

    // MARK: - Parse: malformed TOML does not crash

    @Test func parseMalformedDoesNotCrash() {
        let toml = """
            [general
            launch_at_login = true
            broken line without equals

            [apps]
            com.app = "garbage"
            """
        let parsed = ConfigManagerImpl.parse(toml)
        #expect(parsed.launchAtLogin == false)  // line inside malformed section ignored
    }

    // MARK: - Parse: app modes

    @Test func parseAppModesAllVariants() {
        let toml = """
            [apps]
            "a" = "notify"
            "b" = "protect"
            "c" = "silent_quit"
            "d" = "hide"
            "e" = "unknown_mode"
            """
        let parsed = ConfigManagerImpl.parse(toml)
        #expect(parsed.appModes["a"] == .notify)
        #expect(parsed.appModes["b"] == .protect)
        #expect(parsed.appModes["c"] == .silentQuit)
        #expect(parsed.appModes["d"] == .hide)
        #expect(parsed.appModes["e"] == nil)
    }

    // MARK: - Serialize: app mode names

    @Test func serializeAppModeNotifies() {
        let serialized = ConfigManagerImpl.serialize(LeafConfig())
        #expect(serialized.contains("[general]"))
        #expect(serialized.contains("launch_at_login = false"))
        #expect(serialized.contains("notify_after_minutes = 15"))
    }

    @Test func serializeIncludesAppModes() {
        var config = LeafConfig()
        config.appModes["com.a"] = .protect
        let serialized = ConfigManagerImpl.serialize(config)
        #expect(serialized.contains("\"com.a\" = \"protect\""))
    }

    // MARK: - stripComment

    @Test func stripCommentHandlesInlineComments() {
        let toml = "key = \"value\" # this is a comment"
        let parsed = ConfigManagerImpl.parse(toml)
        #expect(parsed.appModes.isEmpty)
    }

    @Test func stripCommentPreservesHashInQuotes() {
        let toml = """
            [apps]
            "com.app" = "notify" # trailing
            """
        let parsed = ConfigManagerImpl.parse(toml)
        #expect(parsed.appModes["com.app"] == .notify)
    }

    // MARK: - clampNotifyMinutes

    @Test func clampNotifyMinutesClampsToNearestValue() {
        #expect(ConfigManagerImpl.clampNotifyMinutes(Int.min) == 5)
        #expect(ConfigManagerImpl.clampNotifyMinutes(Int.max) == 240)
        #expect(ConfigManagerImpl.clampNotifyMinutes(5) == 5)
        #expect(ConfigManagerImpl.clampNotifyMinutes(7) == 5)
        #expect(ConfigManagerImpl.clampNotifyMinutes(12) == 10)
        #expect(ConfigManagerImpl.clampNotifyMinutes(60) == 60)
        #expect(ConfigManagerImpl.clampNotifyMinutes(200) == 240)
        #expect(ConfigManagerImpl.clampNotifyMinutes(999) == 240)
    }

    @Test(arguments: [Int.min, Int.max, 5, 240, 123])
    func parseValidatedHandlesExtremeNotifyMinutes(_ input: Int) {
        let content = "version = 1\n[general]\nnotify_after_minutes = \(input)\n[apps]\n"
        let expected: Int
        switch input {
        case Int.min, 5: expected = 5
        case Int.max, 240: expected = 240
        default: expected = 120
        }
        switch ConfigManagerImpl.parseValidated(content) {
        case .success(let parsed): #expect(parsed.config.notifyAfterMinutes == expected)
        case .failure: Issue.record("valid integer should be normalized")
        }
    }

    // MARK: - parseAppMode / serializeAppMode

    @Test func parseAppModeMapsCorrectly() {
        #expect(ConfigManagerImpl.parseAppMode("notify") == .notify)
        #expect(ConfigManagerImpl.parseAppMode("protect") == .protect)
        #expect(ConfigManagerImpl.parseAppMode("silent_quit") == .silentQuit)
        #expect(ConfigManagerImpl.parseAppMode("hide") == .hide)
        #expect(ConfigManagerImpl.parseAppMode("garbage") == nil)
    }

    @Test func serializeAppModeMapsCorrectly() {
        #expect(ConfigManagerImpl.serializeAppMode(.notify) == "notify")
        #expect(ConfigManagerImpl.serializeAppMode(.protect) == "protect")
        #expect(ConfigManagerImpl.serializeAppMode(.silentQuit) == "silent_quit")
        #expect(ConfigManagerImpl.serializeAppMode(.hide) == "hide")
    }

    // MARK: - Validation: empty / missing version is rejected

    @Test func validateRejectsEmptyOrWhitespaceOnlyContent() {
        #expect(ConfigManagerImpl.validate("") == .empty)
        #expect(ConfigManagerImpl.validate("   \n\n\t  ") == .empty)
    }

    @Test func validateRejectsContentMissingVersion() {
        let toml = """
            [general]
            launch_at_login = true
            """
        #expect(ConfigManagerImpl.validate(toml) == .missingOrUnsupportedVersion)
    }

    @Test func validateRejectsTypoedSectionHeaderWithNoVersion() {
        // The bug this guards against: a typo'd `[apps]` header (here
        // `[aps]`) used to silently parse into a config with every app mode
        // wiped, and that got applied and re-saved as if it were correct.
        let toml = """
            [aps]
            "com.example.App" = "protect"
            """
        #expect(ConfigManagerImpl.validate(toml) != nil)
    }

    @Test func validateAcceptsWellFormedContent() {
        let toml = """
            version = 1

            [general]
            launch_at_login = true
            """
        #expect(ConfigManagerImpl.validate(toml) == nil)
    }

    @Test func parseValidatedFailsClosedForInvalidContent() {
        switch ConfigManagerImpl.parseValidated("") {
        case .success:
            Issue.record("expected .failure for empty content")
        case .failure(let error):
            #expect(error == .empty)
        }
    }

    @Test func parseValidatedSucceedsAndSurfacesWarningsForUnknownKeys() {
        let toml = """
            version = 1

            [general]
            launch_at_login = true
            mystery_key = 1

            [apps]
            "com.example.App" = "protect"
            """
        switch ConfigManagerImpl.parseValidated(toml) {
        case .success(let parsed):
            #expect(parsed.config.launchAtLogin == true)
            #expect(parsed.warnings.contains("unknown key 'mystery_key' in [general]"))
            #expect(parsed.config.appModes["com.example.App"] == .protect)
        case .failure:
            Issue.record("expected .success for otherwise well-formed content")
        }
    }

    @Test(arguments: [
        "version = 1\n[apps]\n\"com.example.Keep\" = \"protect",
        "version = 1\n[apps",
        "version = 1\n[aps]\n\"com.example.Keep\" = \"protect\"",
        "version = 1\n[apps]\n\"com.example.Keep\" = \"invalid\"",
        "version = 1\n[general]\nsmart_alerts = maybe",
        "version = 1\n[general]\nnotify_after_minutes = soon",
        "version = 1\n[apps]\n\"com.example.Keep\" = \"protect\"\n\"com.example.Keep\" = \"hide\"",
        "version = 1\n[general]\nsmart_alerts = true\nsmart_alerts = false",
    ])
    func parseValidatedRejectsMalformedContent(_ content: String) {
        #expect(ConfigManagerImpl.validate(content) != nil)
        if case .success = ConfigManagerImpl.parseValidated(content) {
            Issue.record("malformed content was accepted")
        }
    }

    @Test func emptyAppsSectionIntentionallyRemovesModes() {
        let content = "version = 1\n[apps]\n"
        switch ConfigManagerImpl.parseValidated(content) {
        case .success(let parsed): #expect(parsed.config.appModes.isEmpty)
        case .failure: Issue.record("empty [apps] should be valid")
        }
    }

    // MARK: - configFromUserDefaults migration

    @Test func configFromUserDefaultsReadsAllKeys() {
        // Uses a disposable suite so this test never touches the shared
        // com.satwik.Leaf UserDefaults domain of a real, installed Leaf.
        let suiteName = "com.leaf.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "launchAtLogin")
        defaults.set(true, forKey: "quitWithoutNotify")
        defaults.set(60, forKey: "closingTime")
        defaults.set(false, forKey: "smartAlerts")
        defaults.set(false, forKey: "detectBackgroundActivity")
        let appModes: [String: AppMode] = ["com.a": .protect]

        let config = ConfigManagerImpl.configFromUserDefaults(appModes: appModes, defaults: defaults)

        #expect(config.launchAtLogin == true)
        #expect(config.quitWithoutNotify == true)
        #expect(config.notifyAfterMinutes == 60)
        #expect(config.smartAlerts == false)
        #expect(config.keepActiveAppsAlive == false)
        #expect(config.appModes["com.a"] == .protect)
    }
}
