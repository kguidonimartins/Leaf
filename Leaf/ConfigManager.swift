import Darwin
import Foundation
import ServiceManagement
import os

struct LeafConfig: Equatable {
    var launchAtLogin: Bool = false
    var quitWithoutNotify: Bool = false
    var notifyAfterMinutes: Int = 15
    var smartAlerts: Bool = true
    var keepActiveAppsAlive: Bool = true
    var appModes: [String: AppMode] = [:]

    static let allowedNotifyMinutes = [5, 10, 15, 30, 60, 120, 240]

    static func clampNotifyMinutes(_ value: Int) -> Int {
        allowedNotifyMinutes.min(by: { abs($0 - value) < abs($1 - value) }) ?? 15
    }
}

enum ConfigManager {
    static let shared = ConfigManagerImpl()

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/leaf/config.toml")
    }

    /// True when this process is hosting the XCTest bundle (`TEST_HOST`).
    /// Guards every path that could otherwise touch the real user's shared
    /// UserDefaults domain, config.toml, or login items during `make test`.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

final class ConfigManagerImpl: NSObject {
    private weak var tracker: Tracker?

    /// Where `config.toml` (or a symlink to it) lives. Injectable so tests
    /// can point I/O at a scratch directory instead of the real
    /// `~/.config/leaf`.
    private let configURL: URL
    /// UserDefaults domain mirrored to/from config.toml. Injectable so tests
    /// never read or write the real, shared `com.satwik.Leaf` domain.
    private let defaults: UserDefaults

    private let ioQueue = DispatchQueue(label: "com.leaf.config.io")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leaf.app", category: "config")
    private var saveWorkItem: DispatchWorkItem?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var directoryFileDescriptor: Int32 = -1
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    private var suppressSave = false
    // Only ever mutated on `ioQueue` in production (see `scheduleSave` and
    // `apply`), which is what makes the `write(content:)` comparison against
    // it race-free without a lock. Tests that call `saveToDisk()` directly
    // touch it synchronously on their own single thread, which is fine.
    private var lastAppliedContent: String?

    init(configURL: URL = ConfigManager.configURL, defaults: UserDefaults = .standard) {
        self.configURL = configURL
        self.defaults = defaults
        super.init()
    }

    func configure(tracker: Tracker) {
        self.tracker = tracker
    }

    func start() {
        loadFromDiskOrMigrate()
        startObservingUserDefaults()
        startDirectoryWatcher()
        startFileWatcher()
    }

    func notifyAppModesChanged() {
        guard !suppressSave, !ConfigManager.isRunningTests else { return }
        scheduleSave()
    }

    // MARK: - Load / save

    /// `configURL` with any symlinks resolved to their real target (e.g. a
    /// dotfiles repo). Writes and reads must go through this so a symlinked
    /// config.toml gets its target updated in place instead of being
    /// replaced by a plain file, which would silently sever the link.
    func resolvedConfigURL() -> URL {
        configURL.resolvingSymlinksInPath()
    }

    // `internal` (not `private`) below so `@testable import Leaf` can drive
    // I/O synchronously against an injected scratch `configURL`, without
    // going through the singleton/observer glue that's deliberately gated
    // behind `ConfigManager.isRunningTests`.
    func loadFromDiskOrMigrate() {
        let url = resolvedConfigURL()
        ensureConfigDirectoryExists()

        if FileManager.default.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            applyValidatedContentOrKeepCurrent(content)
            return
        }

        let migrated = Self.configFromUserDefaults(appModes: tracker?.appModes ?? [:], defaults: defaults)
        apply(migrated, sourceContent: nil)
        scheduleSave(immediate: true)
    }

    /// Parses and validates `content`; applies it only when valid. An empty
    /// file or one missing `version = 1` (e.g. a typo'd `[apps]` header that
    /// silently dropped every app mode) is left entirely untouched: nothing
    /// is applied, `lastAppliedContent` isn't updated, and the next save
    /// still reflects whatever was last known-good, instead of baking the
    /// loss into UserDefaults and then into the file itself.
    private func applyValidatedContentOrKeepCurrent(_ content: String) {
        switch Self.parseValidated(content) {
        case .success(let parsed):
            for warning in parsed.warnings {
                logger.notice("config.toml: \(warning, privacy: .public)")
            }
            apply(parsed.config, sourceContent: content)
        case .failure(let error):
            logger.error("config.toml is invalid, keeping current settings — \(error.description, privacy: .public)")
        }
    }

    /// Snapshots `tracker.appModes` and `defaults` into an immutable,
    /// serialized string *on the calling thread* — always the main thread in
    /// practice, since every production mutation of `tracker.appModes` and
    /// every `defaults.set` in this app already happens there — and hands
    /// only that string to `ioQueue`. This is what keeps the I/O queue from
    /// ever reading `tracker`/`defaults` concurrently with a main-thread
    /// mutation of them.
    private func scheduleSave(immediate: Bool = false) {
        guard !suppressSave else { return }

        let config = Self.configFromUserDefaults(appModes: tracker?.appModes ?? [:], defaults: defaults)
        let content = Self.serialize(config)

        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.write(content: content)
        }
        saveWorkItem = work

        if immediate {
            ioQueue.async(execute: work)
        } else {
            ioQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// Convenience for tests: snapshots and writes synchronously on the
    /// calling thread. Production code always goes through `scheduleSave`,
    /// which snapshots on the main thread but performs the write on `ioQueue`.
    func saveToDisk() {
        let config = Self.configFromUserDefaults(appModes: tracker?.appModes ?? [:], defaults: defaults)
        write(content: Self.serialize(config))
    }

    /// The actual file I/O: temp write, backup, atomic replace. Touches only
    /// its `content` parameter and `lastAppliedContent` — never `tracker` or
    /// `defaults` — so it's safe to run on `ioQueue` concurrently with
    /// main-thread mutations of those.
    private func write(content: String) {
        guard content != lastAppliedContent else { return }

        ensureConfigDirectoryExists()
        // Resolved *before* writing so a symlinked config.toml (e.g. into a
        // dotfiles repo) gets its target updated in place; the temp file and
        // backup live next to that resolved target, not next to the link.
        let targetURL = resolvedConfigURL()
        let tempURL = targetURL.deletingLastPathComponent().appendingPathComponent(".config.toml.tmp")

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                let backupURL = targetURL.deletingLastPathComponent().appendingPathComponent("config.toml.bak")
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: targetURL, to: backupURL)
            }
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tempURL)
            lastAppliedContent = content
            rearmFileWatcher()
        } catch {
            logger.error("Failed to write config.toml — \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func reloadFromDiskIfChanged() {
        let url = resolvedConfigURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            guard content != lastAppliedContent else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyValidatedContentOrKeepCurrent(content)
            }
        } catch {
            logger.error("Failed to reload config.toml — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ config: LeafConfig, sourceContent: String?) {
        suppressSave = true
        defer { suppressSave = false }

        defaults.set(config.launchAtLogin, forKey: "launchAtLogin")
        defaults.set(config.quitWithoutNotify, forKey: "quitWithoutNotify")
        defaults.set(config.notifyAfterMinutes, forKey: "closingTime")
        defaults.set(config.smartAlerts, forKey: "smartAlerts")
        defaults.set(config.keepActiveAppsAlive, forKey: "detectBackgroundActivity")

        tracker?.appModes = config.appModes

        // Never touch the real login item registration from a test process.
        if !ConfigManager.isRunningTests {
            Self.applyLaunchAtLogin(config.launchAtLogin)
        }

        // Confined to `ioQueue` (see `lastAppliedContent`'s declaration)
        // rather than set here on the main thread directly. Enqueued before
        // this function returns, so any `scheduleSave` the caller triggers
        // right after `apply` (e.g. the first-launch migration path) is
        // still guaranteed to see this value first, preserving the same
        // ordering as before — just race-free.
        let appliedContent = sourceContent ?? Self.serialize(config)
        ioQueue.async { [weak self] in
            self?.lastAppliedContent = appliedContent
        }
    }

    private func ensureConfigDirectoryExists() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - UserDefaults observation

    private func startObservingUserDefaults() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func userDefaultsDidChange(_ notification: Notification) {
        guard !suppressSave else { return }
        scheduleSave()
    }

    // MARK: - File watcher

    /// Watches `~/.config/leaf` itself: catches the symlink (or config.toml)
    /// being created, replaced, or removed — events that never touch the
    /// resolved target's own directory when that target lives elsewhere
    /// (e.g. a dotfiles repo), and which the file watcher below can't see
    /// before a file even exists.
    private func startDirectoryWatcher() {
        let dir = configURL.deletingLastPathComponent()
        ensureConfigDirectoryExists()

        let dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        directoryFileDescriptor = dirFD

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            self?.reloadFromDiskIfChanged()
            // The symlink itself (or config.toml) may have just been
            // created, removed, or repointed — make sure the file watcher
            // tracks whatever now resolves at configURL.
            self?.rearmFileWatcher()
        }
        // Closes exactly the fd this source opened (captured by value), not
        // whatever `directoryFileDescriptor` holds when the cancel handler
        // finally runs — a rearm may have already overwritten it by then,
        // since both run serially on the same ioQueue.
        source.setCancelHandler { [weak self] in
            close(dirFD)
            if self?.directoryFileDescriptor == dirFD {
                self?.directoryFileDescriptor = -1
            }
        }
        directoryWatcher = source
        source.resume()
    }

    /// Watches the resolved target file directly, so an editor that saves in
    /// place (write, no rename) — which a directory-level watch won't catch —
    /// is still picked up, including when the target lives outside
    /// `~/.config/leaf` (a symlinked dotfiles repo).
    private func startFileWatcher() {
        let resolved = resolvedConfigURL()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return }

        let fd = open(resolved.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib, .link],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.reloadFromDiskIfChanged()
            // Many editors save by writing a new inode and renaming it into
            // place; the fd we opened then points at the old, unlinked
            // inode and stops seeing further writes, so reopen on the path.
            if events.contains(.delete) || events.contains(.rename) {
                self.rearmFileWatcher()
            }
        }
        // Closes exactly the fd this source opened (captured by value); see
        // the matching comment on the directory watcher's cancel handler.
        source.setCancelHandler { [weak self] in
            close(fd)
            if self?.fileDescriptor == fd {
                self?.fileDescriptor = -1
            }
        }
        fileWatcher = source
        source.resume()
    }

    private func rearmFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
        startFileWatcher()
    }

    // MARK: - Side effects

    private static let sideEffectLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leaf.app", category: "login-item")

    /// The single place that registers/unregisters Leaf as a login item.
    /// Only calls into SMAppService when `enabled` actually disagrees with
    /// the real, current registration — not on every config load/apply —
    /// so this never reverts a login item the user removed by hand in
    /// System Settings, and never calls `unregister()` on an app that was
    /// never registered (which SMAppService logs as an error).
    static func applyLaunchAtLogin(_ enabled: Bool) {
        let alreadyEnabled = SMAppService.mainApp.status == .enabled
        guard enabled != alreadyEnabled else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sideEffectLogger.error("Failed to update login item — \(error.localizedDescription, privacy: .public)")
        }
    }

    static func configFromUserDefaults(appModes: [String: AppMode], defaults: UserDefaults = .standard) -> LeafConfig {
        return LeafConfig(
            launchAtLogin: defaults.bool(forKey: "launchAtLogin"),
            quitWithoutNotify: defaults.bool(forKey: "quitWithoutNotify"),
            notifyAfterMinutes: clampNotifyMinutes(defaults.object(forKey: "closingTime") as? Int ?? 15),
            smartAlerts: defaults.object(forKey: "smartAlerts") as? Bool ?? true,
            keepActiveAppsAlive: defaults.object(forKey: "detectBackgroundActivity") as? Bool ?? true,
            appModes: appModes
        )
    }

    // MARK: - TOML validation

    enum ConfigValidationError: Error, Equatable, CustomStringConvertible {
        /// The file is empty (or whitespace-only): nothing to apply.
        case empty
        /// No top-level `version = 1` was found. Catches both a genuinely
        /// missing version and the case that motivated this check: a typo'd
        /// section header (e.g. `[aps]` instead of `[apps]`) that would
        /// otherwise silently parse into an empty/partial config and wipe
        /// every app mode.
        case missingOrUnsupportedVersion
        case malformed(line: Int, reason: String)

        var description: String {
            switch self {
            case .empty: return "config.toml is empty"
            case .missingOrUnsupportedVersion: return "config.toml is missing 'version = 1'"
            case .malformed(let line, let reason): return "line \(line): \(reason)"
            }
        }
    }

    struct ParsedConfig {
        var config: LeafConfig
        /// Non-fatal issues (unknown sections/keys/app modes) worth logging,
        /// but that don't invalidate an otherwise well-formed file — keeps
        /// forward/backward compatibility with keys this build doesn't know.
        var warnings: [String] = []
    }

    /// Rejects malformed known settings before any of them can replace the
    /// current configuration. An empty [apps] intentionally clears all modes;
    /// unknown sections are rejected because [aps] is otherwise destructive.
    static func validate(_ content: String) -> ConfigValidationError? {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        var section = ""
        var sawVersion = false
        var seenKeys: [String: Set<String>] = [:]
        for (offset, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    return .malformed(line: lineNumber, reason: "invalid section header")
                }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard section == "general" || section == "apps" else {
                    return .malformed(line: lineNumber, reason: "unknown section [\(section)]")
                }
                guard seenKeys[section] == nil else {
                    return .malformed(line: lineNumber, reason: "duplicate section [\(section)]")
                }
                seenKeys[section] = []
                continue
            }

            guard let separator = unquotedSeparator(in: line) else {
                return .malformed(line: lineNumber, reason: "expected key = value")
            }
            let rawKey = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard let key = parseStringTokenStrict(rawKey), !key.isEmpty,
                  let value = parseStringTokenStrict(rawValue) else {
                return .malformed(line: lineNumber, reason: "invalid key or value")
            }
            guard !(seenKeys[section] ?? []).contains(key) else {
                return .malformed(line: lineNumber, reason: "duplicate key '\(key)'")
            }
            seenKeys[section, default: []].insert(key)

            switch section {
            case "":
                if key == "version" {
                    guard rawValue == "1" else { return .missingOrUnsupportedVersion }
                    sawVersion = true
                }
            case "general":
                switch key {
                case "launch_at_login", "quit_without_notify", "smart_alerts", "keep_active_apps_alive":
                    guard rawValue == "true" || rawValue == "false" else {
                        return .malformed(line: lineNumber, reason: "invalid Boolean for '\(key)'")
                    }
                case "notify_after_minutes":
                    guard Int(rawValue) != nil else {
                        return .malformed(line: lineNumber, reason: "invalid integer for '\(key)'")
                    }
                default: break
                }
            case "apps":
                guard parseAppMode(value) != nil else {
                    return .malformed(line: lineNumber, reason: "invalid mode for '\(key)'")
                }
            default: break
            }
        }
        return sawVersion ? nil : .missingOrUnsupportedVersion
    }

    private static func unquotedSeparator(in line: String) -> String.Index? {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\", quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character == "=", !quoted { return index }
        }
        return nil
    }

    private static func parseStringTokenStrict(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard raw.hasPrefix("\"") else {
            return raw.contains("\"") ? nil : raw
        }
        guard raw.hasSuffix("\""), raw.count >= 2 else { return nil }
        var result = ""
        var escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                guard character == "\"" || character == "\\" else { return nil }
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return nil
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    /// Validates, then parses with diagnostics. This is what load/reload
    /// should use; `parse(_:)` stays the permissive, always-succeeds parser
    /// used for round-tripping and by callers that already know the content
    /// is well-formed (e.g. immediately after `serialize`).
    static func parseValidated(_ content: String) -> Result<ParsedConfig, ConfigValidationError> {
        if let error = validate(content) {
            return .failure(error)
        }
        return .success(parseWithDiagnostics(content))
    }

    // MARK: - TOML parse / serialize (pure)

    static func parse(_ content: String) -> LeafConfig {
        parseWithDiagnostics(content).config
    }

    private static func parseWithDiagnostics(_ content: String) -> ParsedConfig {
        var config = LeafConfig()
        var section = ""
        var warnings: [String] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if section != "general" && section != "apps" {
                    warnings.append("unknown section [\(section)]")
                }
                continue
            }

            guard let separator = unquotedSeparator(in: line) else { continue }
            let rawKey = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            let key = parseStringToken(rawKey) ?? rawKey
            guard let value = parseValue(rawValue) else { continue }

            switch section {
            case "general":
                if !applyGeneralKey(key, value: value, to: &config) {
                    warnings.append("unknown key '\(key)' in [general]")
                }
            case "apps":
                if let mode = parseAppMode(value) {
                    config.appModes[key] = mode
                } else {
                    warnings.append("unknown app mode '\(value)' for '\(key)'")
                }
            case "":
                if key != "version" {
                    warnings.append("unknown top-level key '\(key)'")
                }
            default:
                break
            }
        }

        config.notifyAfterMinutes = clampNotifyMinutes(config.notifyAfterMinutes)
        return ParsedConfig(config: config, warnings: warnings)
    }

    static func serialize(_ config: LeafConfig) -> String {
        var lines: [String] = [
            "# Managed by Leaf. Hand-editable: changes are applied live.",
            "# Unknown keys and comments are discarded whenever Leaf rewrites this file.",
            "version = 1",
            "",
            "[general]",
            "launch_at_login = \(config.launchAtLogin)",
            "quit_without_notify = \(config.quitWithoutNotify)",
            "notify_after_minutes = \(clampNotifyMinutes(config.notifyAfterMinutes))",
            "smart_alerts = \(config.smartAlerts)",
            "keep_active_apps_alive = \(config.keepActiveAppsAlive)",
            "",
            "# Per-app modes: notify | protect | silent_quit | hide",
            "[apps]",
        ]

        let sortedApps = config.appModes.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        for (bundleID, mode) in sortedApps {
            lines.append("\(quote(bundleID)) = \"\(serializeAppMode(mode))\"")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Applies a recognized `[general]` key to `config`, returning whether
    /// the key was recognized (regardless of whether its value parsed).
    @discardableResult
    private static func applyGeneralKey(_ key: String, value: String, to config: inout LeafConfig) -> Bool {
        switch key {
        case "launch_at_login":
            config.launchAtLogin = parseBool(value) ?? config.launchAtLogin
        case "quit_without_notify":
            config.quitWithoutNotify = parseBool(value) ?? config.quitWithoutNotify
        case "notify_after_minutes":
            if let minutes = Int(value) {
                config.notifyAfterMinutes = minutes
            }
        case "smart_alerts":
            config.smartAlerts = parseBool(value) ?? config.smartAlerts
        case "keep_active_apps_alive":
            config.keepActiveAppsAlive = parseBool(value) ?? config.keepActiveAppsAlive
        default:
            return false
        }
        return true
    }

    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var escaped = false
        var result = ""
        for char in line {
            if escaped {
                escaped = false
                result.append(char)
                continue
            }
            if char == "\\" {
                escaped = true
                result.append(char)
                continue
            }
            if char == "\"" {
                inQuotes.toggle()
                result.append(char)
                continue
            }
            if char == "#", !inQuotes {
                return result
            }
            result.append(char)
        }
        return result
    }

    private static func parseValue(_ raw: String) -> String? {
        if raw.hasPrefix("\"") {
            return parseStringToken(raw)
        }
        return raw
    }

    private static func parseStringToken(_ raw: String) -> String? {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else {
            return raw.isEmpty ? nil : raw
        }
        let inner = String(raw.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static func parseAppMode(_ raw: String) -> AppMode? {
        switch raw.lowercased() {
        case "notify": return .notify
        case "protect": return .protect
        case "silent_quit", "silentquit": return .silentQuit
        case "hide": return .hide
        default: return nil
        }
    }

    static func serializeAppMode(_ mode: AppMode) -> String {
        switch mode {
        case .notify: return "notify"
        case .protect: return "protect"
        case .silentQuit: return "silent_quit"
        case .hide: return "hide"
        }
    }

    static func clampNotifyMinutes(_ value: Int) -> Int {
        LeafConfig.clampNotifyMinutes(value)
    }
}
