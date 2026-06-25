
import SwiftUI

struct MenuView: View {
    
    var tracker: Tracker
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading) {
                if tracker.runningApps.count > 0 {
                    ForEach(Array(tracker.runningApps), id: \.key) { app in
                        AppView(app: app, tracker: tracker, mode: tracker.appModes[app.key.bundleIdentifier ?? ""] ?? .notify)
                    }
                } else {
                    HStack {
                        Image(systemName: "leaf.fill")
                            .imageScale(.large)
                            .foregroundStyle(.green)
                        VStack {
                            Text("No active apps")
                        }
                    }
                }
            }
            .padding(5)
            
            Divider()
                .padding(0.5)
            
            ButtonsView()
                .padding(.bottom, 1.5)
        }
        .frame(width: 230)
        .padding(6)
        .onAppear {
            tracker.refreshApps()
        }
    }
}

struct AppView: View {
    
    var app: (key: NSRunningApplication, value: TimeInterval)
    var tracker: Tracker
    var mode: AppMode
    
    @Environment(\.colorScheme) var colorScheme

    @State private var hoveringApp: String? = nil
    
    private var bundleID: String { app.key.bundleIdentifier ?? "" }
    private var isHovering: Bool { hoveringApp == app.key.bundleIdentifier }
    
    var body: some View {
        HStack(alignment: .center) {
            
            if let icon = app.key.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .opacity(mode == .protect ? 0.6 : 1.0)
            }
            
            Text(app.key.localizedName ?? "Unknown")
                .foregroundStyle(mode == .protect ? Color.primary.opacity(0.5) : .primary)
                
            Spacer()
            
            // Column 1 - Protect ("never close")
            if isHovering || mode == .protect {
                Button {
                    tracker.toggleProtect(app: bundleID)
                } label: {
                    Image(systemName: mode == .protect ? "shield.fill" : "shield")
                        .frame(height: 15)
                        .foregroundStyle(mode == .protect ? Color.green : Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Never close this app")
            }
            
            // Column 2 - Hide
            if isHovering || mode == .hide {
                Button {
                    tracker.toggleHide(app: bundleID)
                } label: {
                    Image(systemName: mode == .hide ? "eye.fill" : "eye")
                        .frame(height: 15)
                        .foregroundStyle(mode == .hide ? Color.blue : Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Hide this app")
            }

            // Column 3 - Silent quit ("close without notifying")
            if isHovering || mode == .silentQuit {
                Button {
                    tracker.toggleSilentQuit(app: bundleID)
                } label: {
                    Image(systemName: mode == .silentQuit ? "bolt.fill" : "bolt")
                        .frame(height: 15)
                        .foregroundStyle(mode == .silentQuit ? Color.orange : Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Quit this app without notifying")
            }
        }
        .onHover { hovering in
            hoveringApp = hovering ? app.key.bundleIdentifier : nil
        }
    }
}

struct ButtonsView: View {
    
    enum HoverOver: Hashable {
        case settings
        case quit
    }
    
    @Environment(\.openSettings) private var openSettings
    @State private var hoveredButton: HoverOver? = nil
    
    var body: some View {
        
        VStack(alignment: .leading, spacing: 1) {
            
            // Settings button
            Group {
                Button {
                    openSettings()
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Settings")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4.5)
                        .foregroundStyle(hoveredButton == .settings ? Color.white : Color.primary)
                        .background(
                            Group {
                                if hoveredButton == .settings {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.blue.opacity(0.8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.clear)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredButton = hovering ? .settings : nil
                }
            }
            
            // Quit button
            Group {
                Button {
                    NSApplication.shared.terminate(self)
                } label: {
                    Text("Quit")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4.5)
                        .foregroundStyle(hoveredButton == .quit ? Color.white : Color.primary)
                        .background(
                            Group {
                                if hoveredButton == .quit {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.blue.opacity(0.8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.clear)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredButton = hovering ? .quit : nil
                }
            }
        }
    }
}
