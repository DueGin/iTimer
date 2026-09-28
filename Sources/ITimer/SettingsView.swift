import AppKit
import ITimerCore
import ServiceManagement
import SwiftUI

enum Preferences {
    static let brainSplitNudge = "itimer.nudge.brainSplit"
    static let longRunNudge = "itimer.nudge.longRun"

    static func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

struct SettingsView: View {
    var store: TaskStore
    @AppStorage(Preferences.brainSplitNudge) private var brainSplitNudge = true
    @AppStorage(Preferences.longRunNudge) private var longRunNudge = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Stepper(value: thresholdBinding, in: BrainSplitRules.minimumThreshold...BrainSplitRules.maximumThreshold) {
                    HStack {
                        Text("脑裂线")
                        Spacer()
                        ThreadMeter(running: store.brainSplitThreshold, threshold: store.brainSplitThreshold, slotWidth: 12)
                        Text("\(store.brainSplitThreshold) 个线程")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings-threshold")
            } header: {
                Text("注意力")
            } footer: {
                Text("同时计时的任务达到这个数就算脑裂。大多数人超过 2 个就开始丢东西。")
            }

            Section("提醒") {
                Toggle("脑裂时提醒我", isOn: $brainSplitNudge)
                Toggle("单个任务连续计时 \(Int(NudgeCenter.longRunThreshold / 3600)) 小时提醒（可能忘了暂停）", isOn: $longRunNudge)
            }

            Section {
                Toggle("把任务写入日历", isOn: calendarBinding)
                    .accessibilityIdentifier("calendar-sync-toggle")
                if let status = calendarStatus {
                    LabeledContent("状态", value: status)
                }
                if case .denied = CalendarManager.shared.syncer.availability {
                    Link("去系统设置开启日历权限", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            } header: {
                Text("日历")
            } footer: {
                Text("单向写入名为「iTimer」的日历，暂停、完成、改名都会同步。")
            }

            Section("通用") {
                Toggle("登录时启动", isOn: loginBinding)
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent("数据文件") {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url])
                    }
                    .buttonStyle(PillButtonStyle(tint: .accentColor))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var thresholdBinding: Binding<Int> {
        Binding(get: { store.brainSplitThreshold }, set: { store.setThreshold($0) })
    }

    private var calendarBinding: Binding<Bool> {
        Binding(
            get: { store.calendarSyncEnabled },
            set: { on in
                if on {
                    Task { await CalendarManager.shared.requestEnable() }
                } else {
                    store.setCalendarSyncEnabled(false)
                }
            }
        )
    }

    private var calendarStatus: String? {
        guard store.calendarSyncEnabled else { return nil }
        switch CalendarManager.shared.syncer.availability {
        case .granted(let name): return "写入「\(name)」"
        case .denied: return "无权限"
        case .notDetermined: return "待授权"
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { on in
                do {
                    if on {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginError = nil
                } catch {
                    loginError = "设置失败：\(error.localizedDescription)"
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }
}
