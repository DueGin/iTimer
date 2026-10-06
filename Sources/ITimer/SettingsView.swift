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
    @State private var newCollection = ""

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

            Section {
                if store.collections.isEmpty {
                    Text("还没有集合。新建一个，再把任务归进去。")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(store.collections.enumerated()), id: \.element.id) { index, collection in
                    CollectionRow(
                        collection: collection,
                        isFirst: index == 0,
                        isLast: index == store.collections.count - 1,
                        store: store
                    )
                }
                HStack {
                    TextField("新集合", text: $newCollection)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCollection)
                        .accessibilityIdentifier("settings-new-collection")
                    Button("添加", action: addCollection)
                        .disabled(TaskCollection.clean(newCollection).isEmpty)
                }
            } header: {
                Text("任务集合")
            } footer: {
                Text("集合由你新建，不会自动出现。一个任务归入一个集合，另可加多个标签。右键任务即可归入或移出。删除集合后，其中的任务仍在，只是不再归集。")
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

    private func addCollection() {
        if store.addCollection(newCollection) != nil { newCollection = "" }
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

private struct CollectionRow: View {
    var collection: TaskCollection
    var isFirst: Bool
    var isLast: Bool
    var store: TaskStore
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(0..<TaskStore.collectionColorCount, id: \.self) { index in
                    Button {
                        store.setCollectionColor(id: collection.id, color: index)
                    } label: {
                        Label {
                            Text(index == collection.color ? "当前颜色" : "颜色 \(index + 1)")
                        } icon: {
                            Image(nsImage: Self.swatch(Theme.collectionColor(index: index)))
                        }
                    }
                }
            } label: {
                Circle().fill(Theme.collectionColor(index: collection.color)).frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("换颜色")
            TextField("名称", text: $name)
                .textFieldStyle(.plain)
                .onSubmit(commit)
            let count = store.tasks.filter { $0.collectionID == collection.id && $0.isRoot }.count
            if count > 0 {
                Text("\(count) 个任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button { store.moveCollection(id: collection.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(isFirst)
                .help("上移")
            Button { store.moveCollection(id: collection.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(isLast)
                .help("下移")
            Button(role: .destructive) { store.removeCollection(id: collection.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("删除集合，其中的任务保留")
        }
        .onAppear { name = collection.name }
        .onChange(of: collection.name) { _, new in name = new }
    }

    private func commit() {
        if !store.renameCollection(id: collection.id, to: name) { name = collection.name }
    }

    /// Menu items only render images, not shapes.
    private static func swatch(_ color: Color) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}
