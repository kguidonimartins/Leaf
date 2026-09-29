import SwiftUI

struct SettingsView: View {

    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("quitWithoutNotify") private var quitWithoutNotify: Bool = false
    @AppStorage("smartAlerts") private var smartAlerts: Bool = true
    @AppStorage("detectBackgroundActivity") private var detectBackgroundActivity: Bool = true
    @State private var loginStatus: LoginItemStatus = .notRegistered

    /// Shared width for the controls column so every switch and caption lines up.
    private let contentWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .center, spacing: 12.5) {
            
            Spacer()
            
            HStack {
                Text("Leaf")
                    .font(.system(size: 24))
                    .kerning(0.3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.green.gradient)
                
                Image(systemName: "leaf.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 25, height: 25)
                    .foregroundStyle(Color.green.gradient)
            }
            .padding(1)
            
            VStack(alignment: .leading, spacing: 14) {
                
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        ConfigManager.shared.setLaunchAtLoginFromUI(enabled)
                        loginStatus = ConfigManagerImpl.currentLoginStatus()
                        launchAtLogin = ConfigManagerImpl.loginToggleValue(for: loginStatus)
                    }
                )) {
                    Text("Launch at login")
                        .padding(2)
                }
                .toggleStyle(.switch)
                if loginStatus == .requiresApproval {
                    Text("Approve Leaf in System Settings → Login Items to finish enabling this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                toggleSetting(
                    "Quit without notifying",
                    caption: "Default for newly detected apps. Per-app settings always take precedence.",
                    isOn: $quitWithoutNotify
                )
                
                StepperView()
                    .frame(maxWidth: .infinity, alignment: .center)
                
                toggleSetting(
                    "Smart Alerts",
                    caption: "Only warns you about inactive apps with high memory usage",
                    isOn: $smartAlerts
                )
                
                toggleSetting(
                    "Keep active apps alive",
                    caption: "Won't close apps using audio or CPU in the background, like calls or video",
                    isOn: $detectBackgroundActivity
                )
            }
            .frame(width: contentWidth)
            .font(.system(size: 13))
            .shadow(radius: 0.2)
            .fontDesign(.monospaced)
            .foregroundStyle(colorScheme == .dark ? Color.primary : Color.black.opacity(0.75))
            .tint(Color.green)

            Spacer()
            
            VStack {
                Divider().frame(width: 270).padding(.bottom, 8)
                HStack(alignment: .center, spacing: 4) {
                    
                    Text("Developed by")
                        .font(.system(size: 11))
                    Link("Satwik", destination: URL(string: "https://x.com/satwxyz")!)
                        .padding(1)
                        .font(.system(size: 11))
                    Text("👾")
                }
                .fontDesign(.monospaced)
            }
            
        }
        .padding()
        .frame(width: 460, height: 500)
        .onAppear {
            // UserDefaults can drift from the real registration (e.g. the
            // user removed Leaf from Login Items in System Settings), so
            // show the actual status rather than trusting the stored value.
            loginStatus = ConfigManagerImpl.currentLoginStatus()
            launchAtLogin = ConfigManagerImpl.loginToggleValue(for: loginStatus)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .presentedWindowStyle(.titleBar)
    }
    
    /// A switch with a wrapping caption underneath, left-aligned within the
    /// shared controls column so switches and captions line up across rows.
    @ViewBuilder
    private func toggleSetting(_ title: String, caption: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn) {
                Text(title)
                    .padding(2)
            }
            .toggleStyle(.switch)
            
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
}

#Preview {
    SettingsView()
}

struct StepperView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @AppStorage("closingTime") private var closingTime: Int = 15

    let options: [Int: String] = [
        5 : "5 mins",
        10 : "10 mins",
        15 : "15 mins",
        30 : "30 mins",
        60 : "1 hour",
        120 : "2 hours",
        240 : "4 hours"
    ]

    func incrementStep() {
        if closingTime < 15 {
            closingTime += 5
        } else {
            closingTime *= 2
        }
        if closingTime > 240 { closingTime = 5 }
    }

    func decrementStep() {
        if closingTime <= 15 {
            closingTime -= 5
        } else {
            closingTime /= 2
        }
        if closingTime < 5 { closingTime = 240 }
    }

    var body: some View {
        HStack {
            Stepper {
                HStack {
                    Text("Notify After")
                    Text("\(options[closingTime] ?? "Unknown")")
                        .frame(width: 64, height: 25)
                        .italic()
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4).stroke(Color.gray, lineWidth: 1.1)
                        )
                }
                
            } onIncrement: {
                incrementStep()
            } onDecrement: {
                decrementStep()
            }
            
            Text("Of Idle Time")
        }
        .font(.system(size: 13))
        .fontDesign(.monospaced)
        .shadow(radius: 0.2)
        .foregroundStyle(colorScheme == .dark ? Color.primary : Color.black.opacity(0.75))
    }
}
