import Foundation
import Testing
@testable import Leaf

struct TrackerLogicTests {

    // MARK: - Legacy migration

    @Test func migrateLegacyMapsTrueToProtectAndFalseToNotify() {
        let migrated = Tracker.migrateLegacyModes(["a": true, "b": false])
        #expect(migrated["a"] == .protect)
        #expect(migrated["b"] == .notify)
    }

    @Test func migrateLegacyEmptyStaysEmpty() {
        #expect(Tracker.migrateLegacyModes([:]).isEmpty)
    }

    // MARK: - Default mode for new apps

    @Test func defaultModeFollowsGlobalPreference() {
        #expect(Tracker.defaultMode(quitWithoutNotify: false) == .notify)
        #expect(Tracker.defaultMode(quitWithoutNotify: true) == .silentQuit)
    }

    // MARK: - Idle decision

    @Test func protectAlwaysIgnores() {
        let action = Tracker.decideAction(
            mode: .protect,
            idleTime: 9_999,
            closingTimeMinutes: 15,
            isMemoryConsuming: true,
            alreadyNotified: false
        )
        #expect(action == .ignore)
    }

    @Test func notifyTriggersWhenIdleExceededAndMemoryConsuming() {
        let action = Tracker.decideAction(
            mode: .notify,
            idleTime: TimeInterval(16 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: true,
            alreadyNotified: false
        )
        #expect(action == .notify)
    }

    @Test func notifyIgnoresWhenAlreadyNotified() {
        let action = Tracker.decideAction(
            mode: .notify,
            idleTime: TimeInterval(16 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: true,
            alreadyNotified: true
        )
        #expect(action == .ignore)
    }

    @Test func notifyIgnoresBelowIdleThreshold() {
        let action = Tracker.decideAction(
            mode: .notify,
            idleTime: TimeInterval(5 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: true,
            alreadyNotified: false
        )
        #expect(action == .ignore)
    }

    @Test func silentQuitTerminatesWhenIdleExceeded() {
        let action = Tracker.decideAction(
            mode: .silentQuit,
            idleTime: TimeInterval(16 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: true,
            alreadyNotified: false
        )
        #expect(action == .quit)
    }

    @Test func nonMemoryConsumingIsIgnoredForNotifyAndSilentQuit() {
        let notify = Tracker.decideAction(
            mode: .notify,
            idleTime: TimeInterval(16 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: false,
            alreadyNotified: false
        )
        let silent = Tracker.decideAction(
            mode: .silentQuit,
            idleTime: TimeInterval(16 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: false,
            alreadyNotified: false
        )
        #expect(notify == .ignore)
        #expect(silent == .ignore)
    }

    @Test func hideTriggersWhenIdleExceededAndMemoryConsuming() {
        let action = Tracker.decideAction(
            mode: .hide,
            idleTime: TimeInterval(16 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: true,
            alreadyNotified: false
        )
        #expect(action == .hide)
    }

    @Test func hideIgnoresWhenNotMemoryConsuming() {
        let action = Tracker.decideAction(
            mode: .hide,
            idleTime: TimeInterval(16 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: false,
            alreadyNotified: false
        )
        #expect(action == .ignore)
    }

    @Test func hideIgnoresBelowIdleThreshold() {
        let action = Tracker.decideAction(
            mode: .hide,
            idleTime: TimeInterval(5 * 60),
            closingTimeMinutes: 15,
            isMemoryConsuming: true,
            alreadyNotified: false
        )
        #expect(action == .ignore)
    }

    // MARK: - Activity detection

    @Test func foregroundAppIsActive() {
        #expect(Tracker.isConsideredActive(
            isForeground: true,
            hasActiveAudioOutput: false,
            cpuUsage: 0,
            cpuThreshold: 7
        ))
    }

    @Test func audioOutputAloneIsActive() {
        // The "listening only" meeting case: no foreground, no CPU spike, but
        // audio is playing -> keep it alive.
        #expect(Tracker.isConsideredActive(
            isForeground: false,
            hasActiveAudioOutput: true,
            cpuUsage: 0,
            cpuThreshold: 7
        ))
    }

    @Test func cpuAboveThresholdIsActive() {
        #expect(Tracker.isConsideredActive(
            isForeground: false,
            hasActiveAudioOutput: false,
            cpuUsage: 12,
            cpuThreshold: 7
        ))
    }

    @Test func cpuBelowThresholdWithoutOtherSignalsIsInactive() {
        #expect(!Tracker.isConsideredActive(
            isForeground: false,
            hasActiveAudioOutput: false,
            cpuUsage: 3,
            cpuThreshold: 7
        ))
    }

    @Test func noSignalsIsInactive() {
        #expect(!Tracker.isConsideredActive(
            isForeground: false,
            hasActiveAudioOutput: false,
            cpuUsage: 0,
            cpuThreshold: 7
        ))
    }

    // MARK: - Background activity attribution

    @Test func resolveOwnerMatchesHelperInsideAppBundle() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let owner = Tracker.resolveOwner(
            executablePath: path,
            appBundlePaths: ["com.google.Chrome": "/Applications/Google Chrome.app"],
            webKitOwner: nil
        )
        #expect(owner == "com.google.Chrome")
    }

    @Test func resolveOwnerMatchesMainExecutable() {
        let owner = Tracker.resolveOwner(
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            appBundlePaths: ["com.google.Chrome": "/Applications/Google Chrome.app"],
            webKitOwner: nil
        )
        #expect(owner == "com.google.Chrome")
    }

    @Test func resolveOwnerIgnoresSiblingBundleWithSharedPrefix() {
        // "/Applications/Foo.app" must not match "/Applications/FooBar.app".
        let owner = Tracker.resolveOwner(
            executablePath: "/Applications/FooBar.app/Contents/MacOS/FooBar",
            appBundlePaths: ["com.example.Foo": "/Applications/Foo.app"],
            webKitOwner: nil
        )
        #expect(owner == nil)
    }

    @Test func resolveOwnerPicksLongestPrefixForNestedBundles() {
        let owner = Tracker.resolveOwner(
            executablePath: "/Applications/Outer.app/Contents/Frameworks/Inner.app/Contents/MacOS/Inner",
            appBundlePaths: [
                "com.example.Outer": "/Applications/Outer.app",
                "com.example.Inner": "/Applications/Outer.app/Contents/Frameworks/Inner.app"
            ],
            webKitOwner: nil
        )
        #expect(owner == "com.example.Inner")
    }

    @Test func resolveOwnerAttributesSystemWebKitToSafariWhenRunning() {
        let path = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        let owner = Tracker.resolveOwner(
            executablePath: path,
            appBundlePaths: [:],
            webKitOwner: "com.apple.Safari"
        )
        #expect(owner == "com.apple.Safari")
    }

    @Test func resolveOwnerSkipsSystemWebKitWhenSafariNotRunning() {
        let path = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        let owner = Tracker.resolveOwner(
            executablePath: path,
            appBundlePaths: [:],
            webKitOwner: nil
        )
        #expect(owner == nil)
    }

    @Test func resolveOwnerReturnsNilForUnrelatedPath() {
        let owner = Tracker.resolveOwner(
            executablePath: "/usr/libexec/some-daemon",
            appBundlePaths: ["com.google.Chrome": "/Applications/Google Chrome.app"],
            webKitOwner: "com.apple.Safari"
        )
        #expect(owner == nil)
    }

    @Test func resolveOwnerReturnsNilForEmptyPath() {
        let owner = Tracker.resolveOwner(
            executablePath: "",
            appBundlePaths: ["com.google.Chrome": "/Applications/Google Chrome.app"],
            webKitOwner: "com.apple.Safari"
        )
        #expect(owner == nil)
    }

    @Test func aggregateSumsCPUAndOrsAudioPerOwner() {
        let samples = [
            Tracker.ProcessSample(
                pid: 1,
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                memoryMB: 100, cpuPercent: 1, hasAudioOutput: false
            ),
            Tracker.ProcessSample(
                pid: 2,
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/F/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/h",
                memoryMB: 50, cpuPercent: 8, hasAudioOutput: true
            ),
            Tracker.ProcessSample(
                pid: 3,
                executablePath: "/usr/libexec/unrelated",
                memoryMB: 10, cpuPercent: 99, hasAudioOutput: true
            )
        ]
        let signals = Tracker.aggregateSignals(
            samples: samples,
            appBundlePaths: ["com.google.Chrome": "/Applications/Google Chrome.app"],
            webKitOwner: nil
        )
        #expect(signals.count == 1)
        #expect(signals["com.google.Chrome"]?.cpuPercent == 9)
        #expect(signals["com.google.Chrome"]?.hasAudioOutput == true)
    }

    @Test func aggregateAttributesWebKitAudioToSafari() {
        let samples = [
            Tracker.ProcessSample(
                pid: 10,
                executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
                memoryMB: 80, cpuPercent: 15, hasAudioOutput: true
            )
        ]
        let signals = Tracker.aggregateSignals(
            samples: samples,
            appBundlePaths: ["com.apple.Safari": "/Applications/Safari.app"],
            webKitOwner: "com.apple.Safari"
        )
        #expect(signals["com.apple.Safari"]?.hasAudioOutput == true)
        #expect(signals["com.apple.Safari"]?.cpuPercent == 15)
    }

    // MARK: - Toggle exclusivity

    @Test func togglingActiveModeFallsBackToNotify() {
        #expect(Tracker.toggledMode(current: .protect, toggling: .protect) == .notify)
        #expect(Tracker.toggledMode(current: .silentQuit, toggling: .silentQuit) == .notify)
        #expect(Tracker.toggledMode(current: .hide, toggling: .hide) == .notify)
    }

    @Test func togglingSwitchesBetweenModesExclusively() {
        #expect(Tracker.toggledMode(current: .notify, toggling: .protect) == .protect)
        #expect(Tracker.toggledMode(current: .notify, toggling: .silentQuit) == .silentQuit)
        #expect(Tracker.toggledMode(current: .notify, toggling: .hide) == .hide)
        // Switching directly from one active mode to the other never leaves both on.
        #expect(Tracker.toggledMode(current: .silentQuit, toggling: .protect) == .protect)
        #expect(Tracker.toggledMode(current: .protect, toggling: .silentQuit) == .silentQuit)
        #expect(Tracker.toggledMode(current: .hide, toggling: .protect) == .protect)
        #expect(Tracker.toggledMode(current: .protect, toggling: .hide) == .hide)
    }
}
