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
    private var isWritingFile = false
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
            let parsed = Self.parse(content)
            apply(parsed, sourceContent: content)
            return
        }

        let migrated = Self.configFromUserDefaults(appModes: tracker?.appModes ?? [:], defaults: defaults)
        apply(migrated, sourceContent: nil)
        scheduleSave(immediate: true)
    }

    private func scheduleSave(immediate: Bool = false) {
        guard !suppressSave else { return }

        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveToDisk()
        }
        saveWorkItem = work

        if immediate {
            ioQueue.async(execute: work)
        } else {
            ioQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func saveToDisk() {
        let config = Self.configFromUserDefaults(appModes: tracker?.appModes ?? [:], defaults: defaults)
        let content = Self.serialize(config)

        guard content != lastAppliedContent else { return }

        ensureConfigDirectoryExists()
        // Resolved *before* writing so a symlinked config.toml (e.g. into a
        // dotfiles repo) gets its target updated in place; the temp file and
        // backup live next to that resolved target, not next to the link.
        let targetURL = resolvedConfigURL()
        let tempURL = targetURL.deletingLastPathComponent().appendingPathComponent(".config.toml.tmp")

        isWritingFile = true
        defer { isWritingFile = false }

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
        guard !isWritingFile else { return }

        let url = resolvedConfigURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            guard content != lastAppliedContent else { return }
            let parsed = Self.parse(content)
            DispatchQueue.main.async { [weak self] in
                self?.apply(parsed, sourceContent: content)
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

        if let sourceContent {
            lastAppliedContent = sourceContent
        } else {
            lastAppliedContent = Self.serialize(config)
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

    static func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Leaf: Failed to update login item — \(error)")
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

    // MARK: - TOML parse / serialize (pure)

    static func parse(_ content: String) -> LeafConfig {
        var config = LeafConfig()
        var section = ""

        for rawLine in content.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let rawKey = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            let key = parseStringToken(rawKey) ?? rawKey
            guard let value = parseValue(rawValue) else { continue }

            switch section {
            case "general":
                applyGeneralKey(key, value: value, to: &config)
            case "apps":
                if let mode = parseAppMode(value) {
                    config.appModes[key] = mode
                }
            case "":
                if key == "version" { continue }
            default:
                continue
            }
        }

        config.notifyAfterMinutes = clampNotifyMinutes(config.notifyAfterMinutes)
        return config
    }

    static func serialize(_ config: LeafConfig) -> String {
        var lines: [String] = [
            "# Managed by Leaf. Editável à mão: as mudanças são aplicadas ao vivo.",
            "# Chaves desconhecidas e comentários são descartados quando o Leaf reescreve.",
            "version = 1",
            "",
            "[general]",
            "launch_at_login = \(config.launchAtLogin)",
            "quit_without_notify = \(config.quitWithoutNotify)",
            "notify_after_minutes = \(clampNotifyMinutes(config.notifyAfterMinutes))",
            "smart_alerts = \(config.smartAlerts)",
            "keep_active_apps_alive = \(config.keepActiveAppsAlive)",
            "",
            "# Modos por app: notify | protect | silent_quit | hide",
            "[apps]",
        ]

        let sortedApps = config.appModes.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        for (bundleID, mode) in sortedApps {
            lines.append("\(quote(bundleID)) = \"\(serializeAppMode(mode))\"")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func applyGeneralKey(_ key: String, value: String, to config: inout LeafConfig) {
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
            break
        }
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
