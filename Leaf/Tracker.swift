
import Darwin
import UserNotifications
import SwiftUI

/// Per-app behavior when an app stays inactive long enough.
/// The three modes are mutually exclusive.
enum AppMode: String, Codable {
    /// Inactive app triggers a notification with a quit action (default).
    case notify
    /// Inactive app is never touched.
    case `protect`
    /// Inactive app is terminated without any notification.
    case silentQuit
}

@Observable class Tracker: NSObject, UNUserNotificationCenterDelegate {
    
    var runningApps: [NSRunningApplication : TimeInterval] = [:]
    
    @AppStorage("smartAlerts") @ObservationIgnored private var smartAlerts: Bool = true
    /// When on, apps that are playing audio or busy on the CPU in the background
    /// (incl. their helper processes) are kept alive. When off, only the
    /// foreground app counts as active, the way Leaf behaved before.
    @AppStorage("detectBackgroundActivity") @ObservationIgnored private var detectBackgroundActivity: Bool = true
    @AppStorage("closingTime") @ObservationIgnored private var closingTime: Int = 15
    @AppStorage("quitWithoutNotify") @ObservationIgnored private var quitWithoutNotify: Bool = false
    @AppStorage("goingToSleep") @ObservationIgnored private var goingToSleep: Bool = false
    // Legacy storage kept intact for safe rollback; superseded by appModesData.
    @AppStorage("nonNotifyApps") @ObservationIgnored private var nonNotifyAppsData: Data = Data()
    @AppStorage("appModes") @ObservationIgnored private var appModesData: Data = Data()
    
    var appModes: [String : AppMode] = [:] {
        didSet {
            if let encoded = try? JSONEncoder().encode(appModes) {
                appModesData = encoded
            }
        }
    }
    
    @ObservationIgnored private let memoryThresholdMB: Double = 200.0
    /// Recent CPU usage (percent) above which a background app is treated as
    /// active. Conservative on purpose: we'd rather keep a busy app alive than
    /// close something the user is using.
    @ObservationIgnored private let cpuActivityThreshold: Double = 7.0
    /// System browser-engine owner. WebKit content/GPU processes run from the
    /// shared system framework with no public link back to the Safari instance
    /// that spawned them, so their background activity is attributed to Safari.
    /// This is the single, intentional exception to the otherwise list-free,
    /// bundle-path based attribution.
    @ObservationIgnored static let systemWebKitOwnerBundleID = "com.apple.Safari"
    @ObservationIgnored private var sleepStartTime: Date = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var notifiedApps = Set<String>()
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private let audioMonitor: AudioActivityProviding

    init(audioMonitor: AudioActivityProviding = AudioActivityMonitor()) {
        self.audioMonitor = audioMonitor
        super.init()
        if let saved = try? JSONDecoder().decode([String: AppMode].self, from: appModesData),
           !saved.isEmpty {
            appModes = saved
        } else if let legacy = try? JSONDecoder().decode([String: Bool].self, from: nonNotifyAppsData) {
            appModes = Tracker.migrateLegacyModes(legacy)
        }
        UNUserNotificationCenter.current().delegate = self
    }
    
    // MARK: - Pure decision logic (testable, no NSWorkspace dependency)
    
    /// Maps the old boolean "don't notify" map to the new three-mode model.
    /// `true` meant "never touch this app" -> `.protect`; `false` -> `.notify`.
    static func migrateLegacyModes(_ legacy: [String: Bool]) -> [String: AppMode] {
        legacy.mapValues { $0 ? .protect : .notify }
    }
    
    /// Default mode applied to a newly detected app. Every app follows the
    /// global "quit without notifying" preference; activity (audio/CPU) is what
    /// keeps an app alive now, not a hardcoded media-player exception.
    static func defaultMode(quitWithoutNotify: Bool) -> AppMode {
        quitWithoutNotify ? .silentQuit : .notify
    }
    
    /// Resolves the next mode when toggling a given mode on/off.
    /// Toggling the active mode off returns `.notify`; otherwise switches to the
    /// target mode, keeping the three modes mutually exclusive.
    static func toggledMode(current: AppMode, toggling target: AppMode) -> AppMode {
        current == target ? .notify : target
    }
    
    enum IdleAction {
        case ignore
        case notify
        case quit
    }
    
    /// Decides what to do with a single inactive app given its mode and state.
    static func decideAction(mode: AppMode,
                             idleTime: TimeInterval,
                             closingTimeMinutes: Int,
                             isMemoryConsuming: Bool,
                             alreadyNotified: Bool) -> IdleAction {
        if mode == .protect { return .ignore }
        
        let exceededIdle = idleTime > TimeInterval(closingTimeMinutes * 60)
        guard exceededIdle, isMemoryConsuming else { return .ignore }
        
        switch mode {
        case .protect:
            return .ignore
        case .silentQuit:
            return .quit
        case .notify:
            return alreadyNotified ? .ignore : .notify
        }
    }
    
    /// Whether an app should be treated as active (idle timer reset) regardless
    /// of mode. Active means: it's the foreground app, it's currently playing
    /// audio output (covers meetings where the user only listens and background
    /// video/music), or it's burning enough CPU to look in-use.
    static func isConsideredActive(isForeground: Bool,
                                   hasActiveAudioOutput: Bool,
                                   cpuUsage: Double,
                                   cpuThreshold: Double) -> Bool {
        isForeground || hasActiveAudioOutput || cpuUsage >= cpuThreshold
    }
    
    // MARK: - Background activity attribution (testable)
    
    /// A single OS process observed in the system. Used to attribute background
    /// audio/CPU activity to the user-facing app that owns it, since browsers
    /// and Electron apps do their real work in helper processes.
    struct ProcessSample {
        let pid: Int32
        let executablePath: String
        let memoryMB: Double
        let cpuPercent: Double
        let hasAudioOutput: Bool
    }
    
    /// Per-app aggregated activity signals.
    struct ActivitySignals {
        var hasAudioOutput: Bool = false
        var cpuPercent: Double = 0
    }
    
    /// Whether an executable path belongs to the shared system WebKit engine
    /// (Safari's browser engine). These run from the system framework and have
    /// no public link back to the owning app.
    static func isSystemWebKitProcess(executablePath: String) -> Bool {
        executablePath.contains("/WebKit.framework/")
    }
    
    /// Path-component-aware prefix check, so `/Applications/Foo.app` does not
    /// match `/Applications/FooBar.app`.
    static func path(_ path: String, isInsideBundle bundlePath: String) -> Bool {
        if path == bundlePath { return true }
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        return path.hasPrefix(prefix)
    }
    
    /// Resolves the owning app's bundle identifier for a process executable
    /// path. Matches the running app whose bundle directory is the longest path
    /// prefix of the executable (covers Chrome/Teams/Electron helpers that live
    /// inside the app bundle). Falls back to the system WebKit owner for shared
    /// browser-engine processes when that owner is running.
    static func resolveOwner(executablePath: String,
                             appBundlePaths: [String: String],
                             webKitOwner: String?) -> String? {
        guard !executablePath.isEmpty else { return nil }
        
        var best: (bundleID: String, length: Int)?
        for (bundleID, bundlePath) in appBundlePaths {
            guard !bundlePath.isEmpty,
                  path(executablePath, isInsideBundle: bundlePath) else { continue }
            if best == nil || bundlePath.count > best!.length {
                best = (bundleID, bundlePath.count)
            }
        }
        if let best { return best.bundleID }
        
        if let webKitOwner, isSystemWebKitProcess(executablePath: executablePath) {
            return webKitOwner
        }
        return nil
    }
    
    /// Aggregates per-process samples into per-app activity signals: CPU is
    /// summed across all of an app's processes and audio output is OR-ed.
    static func aggregateSignals(samples: [ProcessSample],
                                 appBundlePaths: [String: String],
                                 webKitOwner: String?) -> [String: ActivitySignals] {
        var result: [String: ActivitySignals] = [:]
        for sample in samples {
            guard let owner = resolveOwner(executablePath: sample.executablePath,
                                           appBundlePaths: appBundlePaths,
                                           webKitOwner: webKitOwner) else { continue }
            var signals = result[owner] ?? ActivitySignals()
            signals.cpuPercent += sample.cpuPercent
            signals.hasAudioOutput = signals.hasAudioOutput || sample.hasAudioOutput
            result[owner] = signals
        }
        return result
    }
    
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        initializeRunningApps()
        receiveAppUpdates()
        startTimer()
    }
    
    private func startTimer() {
        self.timer?.invalidate() // Cleans up any old timer
        self.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true, block: { [weak self] _ in
            guard let self else { return }
            
            DispatchQueue.main.async {
                self.refreshApps()
            }
        })
    }
 
    func quitApp(appID: Int32) {
        if let app = NSRunningApplication(processIdentifier: appID) {
            DispatchQueue.main.async {
                app.terminate()
            }
        }
    }
    
    func requestNotificationPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    UserDefaults.standard.set(true, forKey: "hasNotificationAccess")
                } else if let error = error {
                    print("Permission Error: \(error)")
                }
                
                completion(granted)
            }
            
        }
    }
    
    private func initializeRunningApps() {
        
        let apps = NSWorkspace.shared.runningApplications
        
        for app in apps {
            if !isExcludedApp(app: app) {
                DispatchQueue.main.async {
//                    print("initializeRunningApps: Added \(app.localizedName!)")
                    self.runningApps[app] = ProcessInfo.processInfo.systemUptime
                    self.assignDefaultModeIfNeeded(bundleID: app.bundleIdentifier ?? "")
                }
            }
        }
    }
    
    /// Seeds a mode for an app the first time it is seen, leaving existing
    /// user choices untouched.
    private func assignDefaultModeIfNeeded(bundleID: String) {
        guard appModes[bundleID] == nil else { return }
        appModes[bundleID] = Tracker.defaultMode(quitWithoutNotify: quitWithoutNotify)
    }
    
    private func updateActiveApp() {
        
        self.removeTerminatedApps()
        
        if let activeApp = NSWorkspace.shared.frontmostApplication, !isExcludedApp(app: activeApp) {
            DispatchQueue.main.async {
//                print("[\(Date())] - updateActiveApp: Updated \(activeApp.localizedName!)")
                
                self.runningApps[activeApp] = ProcessInfo.processInfo.systemUptime
                
                let bundleID = activeApp.bundleIdentifier ?? ""
                self.notifiedApps.remove(bundleID)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [bundleID])
                
                self.assignDefaultModeIfNeeded(bundleID: bundleID)
            }
        }
    }
    
    internal func refreshApps() {
        removeTerminatedApps()
        trackAndTerminate()
    }
    
    private func addLaunchedApps() {
        let apps = NSWorkspace.shared.runningApplications
        
        for app in apps {
            if !isExcludedApp(app: app) && self.runningApps[app] == nil {
                DispatchQueue.main.async {
                    self.runningApps[app] = ProcessInfo.processInfo.systemUptime
                    self.assignDefaultModeIfNeeded(bundleID: app.bundleIdentifier ?? "")
                }
            }
        }
    }
        
    private func removeTerminatedApps() {
        let apps = NSWorkspace.shared.runningApplications
        
        let currentApps = apps.compactMap { $0 }
        DispatchQueue.main.async {
            self.runningApps = self.runningApps.filter { currentApps.contains($0.key) }
        }
        
        for app in runningApps.keys {
            if isExcludedApp(app: app) {
                runningApps[app] = nil
            }
        }
    }
    
    internal func setMode(app: String, mode: AppMode) {
        DispatchQueue.main.async {
            self.appModes[app] = mode
            if mode != .notify {
                // Clear any pending notification state when the app is no
                // longer in notify mode.
                self.notifiedApps.remove(app)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [app])
            }
        }
    }
    
    /// Toggles "never close" on/off; turning it off falls back to `.notify`.
    internal func toggleProtect(app: String) {
        let current = appModes[app] ?? .notify
        setMode(app: app, mode: Tracker.toggledMode(current: current, toggling: .protect))
    }
    
    /// Toggles "quit without notifying" on/off; turning it off falls back to `.notify`.
    internal func toggleSilentQuit(app: String) {
        let current = appModes[app] ?? .notify
        setMode(app: app, mode: Tracker.toggledMode(current: current, toggling: .silentQuit))
    }
    
    /// Samples every process' memory and recent CPU via `ps`, resolves each
    /// process' executable path, and flags those currently playing audio. The
    /// per-process granularity is what lets us attribute a browser/Electron
    /// app's background activity (which happens in helper processes) back to the
    /// owning app.
    private func getProcessSamples(audioPIDs: Set<Int32>, resolvePaths: Bool) -> [ProcessSample]? {
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(filePath: "/bin/ps")
        task.arguments = ["-e", "-o", "pid=,rss=,%cpu="]
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            task.waitUntilExit()
            
            guard task.terminationStatus == 0 else {
                return nil
            }
            
            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            
            var samples: [ProcessSample] = []
            
            for line in output.components(separatedBy: .newlines) {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count == 3,
                   let pid = Int32(parts[0]),
                   let rssKB = Double(parts[1]),
                   let cpu = Double(parts[2]) {
                    samples.append(ProcessSample(
                        pid: pid,
                        executablePath: resolvePaths ? Tracker.executablePath(forPID: pid) : "",
                        memoryMB: rssKB / 1024.0,
                        cpuPercent: cpu,
                        hasAudioOutput: audioPIDs.contains(pid)
                    ))
                }
            }
            
            return samples.isEmpty ? nil : samples
        } catch {
            print("Leaf: Failed to fetch process samples - \(error)")
            return nil
        }
    }
    
    /// Full executable path for a PID, or an empty string if it can't be read
    /// (e.g. a system process we lack permission for).
    static func executablePath(forPID pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }
    
    private func trackAndTerminate() {
        let now = ProcessInfo.processInfo.systemUptime
        
        // Sampled once per cycle and reused for activity detection (audio/CPU)
        // and the smart-alerts memory filter. Background detection adds the
        // audio query and per-process path resolution; skip that work when off.
        let detectBackground = detectBackgroundActivity
        let activeAudioPIDs = detectBackground ? audioMonitor.activeOutputPIDs() : []
        let samples = (detectBackground || smartAlerts)
            ? getProcessSamples(audioPIDs: activeAudioPIDs, resolvePaths: detectBackground)
            : nil
        let memoryLookupFailed = smartAlerts && samples == nil
        
        // Map each tracked app to its bundle path so helper processes living
        // inside that bundle (browser/Electron helpers) can be attributed back
        // to it. Safari's engine runs in shared system processes, so it gets
        // the dedicated WebKit fallback when it is running.
        var signals: [String: ActivitySignals] = [:]
        if detectBackground {
            var appBundlePaths: [String: String] = [:]
            var safariRunning = false
            for app in runningApps.keys {
                guard let bundleID = app.bundleIdentifier else { continue }
                if let bundlePath = app.bundleURL?.path { appBundlePaths[bundleID] = bundlePath }
                if bundleID == Tracker.systemWebKitOwnerBundleID { safariRunning = true }
            }
            let webKitOwner = safariRunning ? Tracker.systemWebKitOwnerBundleID : nil
            signals = Tracker.aggregateSignals(samples: samples ?? [],
                                               appBundlePaths: appBundlePaths,
                                               webKitOwner: webKitOwner)
        }
        
        var memoryByPID: [Int32: Double] = [:]
        for sample in samples ?? [] { memoryByPID[sample.pid] = sample.memoryMB }
        
        // Reset the idle timer for anything that looks active: the foreground
        // app, an app (incl. its helpers) playing audio, or one busy on the CPU.
        for (app, _) in runningApps {
            let appSignals = signals[app.bundleIdentifier ?? ""]
            if Tracker.isConsideredActive(isForeground: app.isActive,
                                          hasActiveAudioOutput: appSignals?.hasAudioOutput ?? false,
                                          cpuUsage: appSignals?.cpuPercent ?? 0.0,
                                          cpuThreshold: cpuActivityThreshold) {
                self.runningApps[app] = now
            }
        }
        
        var notificationGuys: [(app: NSRunningApplication, idleTime: TimeInterval, memoryUsage: Double)] = []
        
        for (app, lastTime) in runningApps {
            if !app.isActive {
                let idleTime = now - lastTime
                print("\(app.localizedName ?? "Unknown"): \(idleTime)")
                
                let appMemoryUsage = memoryByPID[app.processIdentifier] ?? 0.0
                let isMemoryConsuming = !smartAlerts || memoryLookupFailed || (appMemoryUsage >= memoryThresholdMB)
                
                let bundleID = app.bundleIdentifier ?? ""
                let mode = appModes[bundleID] ?? .notify
                
                switch Tracker.decideAction(mode: mode,
                                            idleTime: idleTime,
                                            closingTimeMinutes: closingTime,
                                            isMemoryConsuming: isMemoryConsuming,
                                            alreadyNotified: notifiedApps.contains(bundleID)) {
                case .ignore:
                    break
                case .quit:
                    quitApp(appID: app.processIdentifier)
                case .notify:
                    notificationGuys.append((app, idleTime, appMemoryUsage))
                }
            }
        }
        
        // Rate-limiting notifications
        if !notificationGuys.isEmpty {
            let sortedGuys = notificationGuys.sorted {
                if smartAlerts && !memoryLookupFailed && $0.memoryUsage != $1.memoryUsage {
                    return $0.memoryUsage > $1.memoryUsage
                }
                
                return $0.idleTime > $1.idleTime
            }
            
            if let primaryGuy = sortedGuys.first {
                sendNotification(app: primaryGuy.app) { [weak self] success in
                    guard success else { return }
                    
                    DispatchQueue.main.async {
                        self?.notifiedApps.insert(primaryGuy.app.bundleIdentifier ?? "unknown")
                    }
                }
            }
        }
        
        // MARK: OLD LOGIC
        
//        for (app, _) in runningApps {
//            if app.isActive {
//                self.runningApps[app] = now
//            } else {
//                // New efficient approach
//                if let lastTime = self.runningApps[app], now - lastTime > TimeInterval(closingTime * 60) && !notifiedApps.contains(app.bundleIdentifier ?? "") && nonNotifyApps[app.bundleIdentifier ?? ""] != true {
//                    if !quitWithoutNotify {
//                        sendNotification(app: app)
//                        notifiedApps.insert(app.bundleIdentifier ?? "shit-happens")
//                    } else {
//                        quitApp(appID: app.processIdentifier)
//                    }
//                } else {
//                }
//            }
//        }
    }
    
    private func sendNotification(app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Want me to quit \(app.localizedName ?? "an unknown app")?"
        content.sound = .default
        content.userInfo = ["persistent" : true, "appID" : app.processIdentifier]
        content.categoryIdentifier = "QUIT_ALERT"
        
        let quitAction = UNNotificationAction(identifier: "QUIT_APP", title: "Quit")
        let category = UNNotificationCategory(
            identifier: "QUIT_ALERT",
            actions: [quitAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
        
        let identifier = app.bundleIdentifier ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("\(error)")
                completion(false)
            } else {
                completion(true)
            }
        }
    }
    
    private func isExcludedApp(app: NSRunningApplication) -> Bool {
        let currentApp = Bundle.main.bundleIdentifier
        
        let excludedApps = [
            "com.apple.dock",
            "com.apple.Siri",
            "com.apple.finder",
            "com.apple.coreautha",
            "com.apple.Spotlight",
            "com.apple.loginwindow",
//            "com.timpler.screenstudio",
            "com.apple.systemuiserver",
            "com.apple.notificationcenterui",
        ]
        
        if app.activationPolicy == .regular && app.bundleIdentifier != currentApp && !excludedApps.contains(app.bundleIdentifier ?? "") {
            return false
        }
        return true
    }
    
    private func resetTimeStamps() {
        let apps = NSWorkspace.shared.runningApplications
        
        for app in apps {
            if !isExcludedApp(app: app) {
                DispatchQueue.main.async {
                    self.runningApps[app] = ProcessInfo.processInfo.systemUptime
                }
            }
        }
    }
    
    private func asleepAndAwake() {
        
        if (goingToSleep) {
//            print("About to stop the timer - \(Date())")
            
            sleepStartTime = Date()
            timer?.invalidate()
            timer = nil
            
        } else {
//            print("About to start the timer again - \(Date())")
            
            let currentTime = Date()
//            print("Difference = \(currentTime.timeIntervalSince(sleepStartTime))")
            
            if currentTime.timeIntervalSince(sleepStartTime) > 30 {
                DispatchQueue.main.async {
                    self.resetTimeStamps()
                }
            }
            
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    self.trackAndTerminate()
                }
            }
        }
    }
    
    private func receiveAppUpdates() {
        
        let notificationCenter = NSWorkspace.shared.notificationCenter
         
        notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
            self.addLaunchedApps()
        }
        
        notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            self.removeTerminatedApps()
        }
        
        notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            self.updateActiveApp()
        }
        
        notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            self.goingToSleep = true
            self.asleepAndAwake()
        }
        
        notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            self.goingToSleep = false
            self.asleepAndAwake()
        }
    }
    
    
    internal func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        
        if response.actionIdentifier == "QUIT_APP" {
            if let appID = response.notification.request.content.userInfo["appID"] as? Int32 {
                quitApp(appID: appID)
            }
        }
        
        if response.notification.request.identifier == "LEAF_UPDATE", response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        
        completionHandler()
    }
    
    internal func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
