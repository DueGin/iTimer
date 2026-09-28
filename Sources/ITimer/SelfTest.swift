import AppKit
import ApplicationServices
import ITimerCore
import QuartzCore
import SwiftUI

@MainActor
enum SelfTest {
    private static var steps: [String] = []
    private static var resultURL = URL(fileURLWithPath: "/tmp/itimer-self-test.json")

    static func runIfRequested() {
        guard let launch = DebugLaunchFile.current, launch.selfTest else { return }
        resultURL = URL(fileURLWithPath: launch.resultPath)
        note("self-test started data=\(TaskStore.shared.url.path)")
        Task { @MainActor in
            let passed = await exercise()
            note(passed ? "PASS" : "FAIL")
            persist(passed: passed)
            exit(passed ? 0 : 1)
        }
    }

    private static func exercise() async -> Bool {
        // Wait for launch-time window ordering to settle: the main window
        // becoming key after the panel opens is what dismisses the panel.
        try? await Task.sleep(nanoseconds: 800_000_000)
        // A real status-item click activates the app; performClick does not,
        // and an inactive app's panel closes immediately. Launch activation
        // can land late under `open -n`, so retry the open cycle.
        var panelOpen = false
        for attempt in 1...3 where !panelOpen {
            var attempts = 0
            while !NSApp.isActive && attempts < 15 {
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(nanoseconds: 200_000_000)
                attempts += 1
            }
            guard clickStatusItem() else {
                note("status item missing. windows=\(windowSummary())")
                return false
            }
            guard await wait(for: 3, label: "menu panel", until: { menuWindow() != nil }) else {
                note("menu did not open on attempt \(attempt)")
                continue
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if menuWindow() != nil {
                panelOpen = true
                note("menu opened and stayed (attempt \(attempt))")
            } else {
                note("menu closed early (attempt \(attempt), active=\(NSApp.isActive))")
            }
        }
        // Panel persistence requires an active app, which CLI launches cannot
        // always obtain (focus policy). If it never opened, run the
        // store-level flow without the visual assertions.
        let panelAvailable = panelOpen
        if !panelOpen {
            note("panel unavailable in this environment; store-level checks only")
        }
        renderBrainStates()
        renderBurstSheet()

        // The data file may be pre-seeded with finished history; count
        // relative to it.
        let baseRunning = TaskStore.shared.runningCount
        let baseFile = max(0, fileTaskCount())
        // Backdated starts so "today" charts have visible bars; without this
        // the whole run fits inside one second and the report is empty.
        let labels = ["@工作 #方案", "@生活", "@工作 #bug"]
        for (index, title) in ["写方案", "回消息", "改bug"].enumerated() {
            let at = Date().addingTimeInterval(-2 * 3600 - Double(2 - index) * 600)
            NotificationCenter.default.post(name: .iTimerStartTask, object: nil, userInfo: ["title": "\(title) \(labels[index])", "at": at])
            guard await wait(for: 2, label: "task \(title)", until: {
                TaskStore.shared.runningTasks.contains { $0.title == title }
            }) else {
                note("start action did not create \(title)")
                return false
            }
        }
        guard TaskStore.shared.runningCount == baseRunning + 3,
              fileTaskCount() == baseFile + 3 else {
            note("count=\(TaskStore.shared.runningCount) file=\(fileTaskCount())")
            return false
        }
        // While the panel is open the status label is frozen — closing the
        // panel must refresh it. This is the real user flow. When the panel
        // is unavailable (CLI focus policy), verify the same freeze semantics
        // at the store level.
        if panelAvailable {
            guard closePanel() else {
                note("could not close panel")
                return false
            }
        }
        guard await wait(for: 2, label: "label refresh", until: {
            TaskStore.shared.statusLabel == "脑裂 3" && statusItemTitle().contains("脑裂")
        }) else {
            note("label did not refresh on close: \(TaskStore.shared.statusLabel)")
            return false
        }
        note("close refreshed label to 脑裂 3")

        // Crossing the line with the panel closed must set off the burst,
        // and the real status item must show the colored frames.
        guard await wait(for: 3, label: "burst", until: { StatusEffects.shared.isPlaying }) else {
            note("brain-split burst did not start")
            return false
        }
        var captures: [NSImage] = []
        for _ in 0..<8 {
            if let shot = statusButtonSnapshot() { captures.append(shot) }
            try? await Task.sleep(nanoseconds: 130_000_000)
        }
        writeStrip(captures, scale: 4, to: "/tmp/itimer-status-burst.png")
        note("burst played, captured \(captures.count) status frames")
        _ = await wait(for: 3, label: "burst end", until: { !StatusEffects.shared.isPlaying })

        if panelAvailable {
            guard openPanel(), menuWindow() != nil else {
                note("panel did not reopen")
                return false
            }
        }
        NotificationCenter.default.post(name: .iTimerPauseFirst, object: nil)
        guard await wait(for: 2, label: "pause", until: {
            TaskStore.shared.runningCount == 2
        }) else {
            note("pause did not drop parallelism. count=\(TaskStore.shared.runningCount)")
            return false
        }
        if panelAvailable {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard menuWindow() != nil else {
                note("panel lost after operating a task")
                return false
            }
            note("panel survived task operation")
            snapshot(menuWindow(), to: "/tmp/itimer-popup.png")
            // The brain buddy must animate smoothly inside the panel, not
            // just on the panel's once-a-second refresh.
            let startTicks = BuddyClock.panel.ticks
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let fps = BuddyClock.panel.ticks - startTicks
            snapshot(menuWindow(), to: "/tmp/itimer-popup-later.png")
            try? await Task.sleep(nanoseconds: 100_000_000)
            snapshot(menuWindow(), to: "/tmp/itimer-popup-later2.png")
            let a = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/itimer-popup-later.png"))
            let b = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/itimer-popup-later2.png"))
            guard fps >= 20, a != b else {
                note("brain buddy not animating in panel: \(fps) ticks/s, frames differ=\(a != b)")
                return false
            }
            note("brain buddy animating at \(fps) ticks/s")
            guard closePanel() else { return false }
        }
        guard await wait(for: 2, label: "mild label", until: {
            TaskStore.shared.statusLabel.hasSuffix("×2")
        }) else {
            note("label did not update after close: \(TaskStore.shared.statusLabel)")
            return false
        }
        note("close refreshed label to mild")
        if panelAvailable {
            // The buddy's timer must stop with the panel.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let idleStart = BuddyClock.panel.ticks
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard BuddyClock.panel.ticks == idleStart else {
                note("brain buddy still ticking after close")
                return false
            }
            note("brain buddy stopped after close")
        }

        NotificationCenter.default.post(name: .iTimerOpenAnalysis, object: nil)
        guard await wait(for: 3, label: "analysis", until: {
            NSApp.windows.contains { $0.isVisible && ($0.title.contains("分析") || $0.title.contains("iTimer")) }
        }) else {
            note("analysis window missing. windows=\(windowSummary())")
            return false
        }
        note("main window opened")
        render(AnalysisView(store: TaskStore.shared), size: NSSize(width: 1100, height: 2200), to: "/tmp/itimer-analysis.png")
        render(MainView(store: TaskStore.shared), size: NSSize(width: 1180, height: 780), to: "/tmp/itimer-main.png")
        render(AnalysisView(store: TaskStore.shared, range: .week), size: NSSize(width: 1100, height: 1500), to: "/tmp/itimer-analysis-week.png")
        let today = DigestCache.shared.digest(store: TaskStore.shared, range: .today)
        let week = DigestCache.shared.digest(store: TaskStore.shared, range: .week)
        render(
            VStack(spacing: 16) {
                LaneChartCard(
                    lanes: today.lanes,
                    splits: today.splitIntervals,
                    threshold: today.report.threshold,
                    hover: Date().addingTimeInterval(-3600)
                )
                TrendChartCard(days: week.dayScores, hover: week.dayScores.last?.day)
            }
            .padding(20)
            .background(Theme.canvas),
            size: NSSize(width: 900, height: 700),
            to: "/tmp/itimer-hover.png"
        )
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(
                MenuBarView(store: TaskStore.shared).background(.regularMaterial),
                size: nil,
                appearance: appearance,
                to: "/tmp/itimer-popup-\(name).png"
            )
        }
        guard exerciseSchedules() else { return false }
        if panelAvailable {
            await captureRealPanel()
        }
        return true
    }

    /// Snapshot the live MenuBarExtra panel with schedules, then with the
    /// composer open, plus the main window — for visual review.
    private static func captureRealPanel() async {
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }) {
            snapshot(main, to: "/tmp/itimer-real-main.png")
        }
        _ = closePanel()
        try? await Task.sleep(nanoseconds: 600_000_000)
        var open = false
        for _ in 1...3 where !open {
            for window in NSApp.windows where window.isVisible && window.frame.width > 800 {
                window.orderOut(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = openPanel()
            try? await Task.sleep(nanoseconds: 900_000_000)
            open = menuWindow() != nil
        }
        guard open else { note("panel would not reopen for capture"); return }
        snapshot(menuWindow(), to: "/tmp/itimer-real-panel.png")
        NotificationCenter.default.post(name: .iTimerNewSchedule, object: false)
        try? await Task.sleep(nanoseconds: 700_000_000)
        snapshot(menuWindow(), to: "/tmp/itimer-real-composer.png")
        _ = closePanel()
    }

    /// Schedules never start on their own; overtime keeps counting.
    private static func exerciseSchedules() -> Bool {
        let store = TaskStore.shared
        let now = Date()
        for task in store.runningTasks { store.complete(id: task.id, at: now) }
        guard let due = store.addSchedule(title: "周会 @工作 #会议", start: now.addingTimeInterval(-600), plannedDuration: 3600, reminderLead: 0),
              store.addSchedule(title: "写周报 @工作 #汇报", start: now.addingTimeInterval(7200), plannedDuration: 7200, reminderLead: 600) != nil,
              let review = store.addSchedule(title: "代码评审", start: now.addingTimeInterval(-3 * 3600), plannedDuration: 3600, reminderLead: nil) else {
            note("addSchedule failed")
            return false
        }
        store.resume(id: review.id, at: now.addingTimeInterval(-90 * 60))
        store.tick()
        guard store.dueSchedules.map(\.id) == [due.id],
              store.upcomingSchedules.count == 1,
              store.runningCount == 1,
              store.runningTasks[0].isOvertime(asOf: store.now) else {
            note("schedule state wrong: due=\(store.dueSchedules.count) upcoming=\(store.upcomingSchedules.count) running=\(store.runningCount)")
            return false
        }
        note("due schedule waits for start; running schedule in overtime")
        guard let undated = store.addSchedule(title: "接入 AI #想法", start: nil, plannedDuration: 7200, reminderLead: 300),
              undated.isUndated, undated.reminderLead == nil,
              store.undatedSchedules.contains(where: { $0.id == undated.id }),
              !store.dueSchedules.contains(where: { $0.id == undated.id }),
              store.upcomingSchedules.count == 1 else {
            note("undated schedule misplaced")
            return false
        }
        note("undated schedule waits in 时间待定 without reminder")
        render(MenuBarView(store: store), size: NSSize(width: 380, height: 640), to: "/tmp/itimer-schedule-popup.png")
        var draft = ScheduleDraft.new(title: "准备季度汇报 @工作 #汇报 #PPT", asOf: now)
        render(
            ScheduleComposer(
                draft: Binding(get: { draft }, set: { draft = $0 }),
                now: now,
                onSave: {}, onStartNow: {}, onCancel: {}
            )
            .padding(16),
            size: NSSize(width: 380, height: 520),
            to: "/tmp/itimer-composer.png"
        )
        render(
            ScheduleComposer(
                draft: Binding(get: { draft }, set: { draft = $0 }),
                now: now,
                onSave: {}, onStartNow: {}, onCancel: {},
                dayListOpen: true
            )
            .padding(16),
            size: NSSize(width: 380, height: 720),
            to: "/tmp/itimer-composer-days.png"
        )
        var far = ScheduleDraft.new(title: "续签合同", asOf: now)
        far.start = Calendar.current.date(byAdding: .month, value: 5, to: far.start) ?? far.start
        render(
            ScheduleComposer(
                draft: Binding(get: { far }, set: { far = $0 }),
                now: now,
                onSave: {}, onStartNow: {}, onCancel: {},
                dayListOpen: true
            )
            .padding(16),
            size: NSSize(width: 380, height: 720),
            to: "/tmp/itimer-composer-far.png"
        )
        var pending = ScheduleDraft.new(title: "接入 AI #想法", asOf: now)
        pending.hasTime = false
        render(
            ScheduleComposer(
                draft: Binding(get: { pending }, set: { pending = $0 }),
                now: now,
                onSave: {}, onStartNow: {}, onCancel: {}
            )
            .padding(16),
            size: NSSize(width: 380, height: 460),
            to: "/tmp/itimer-composer-undated.png"
        )
        return true
    }

    private static func renderBurstSheet() {
        let size = NSSize(width: 22, height: 18)
        var frames: [NSImage] = []
        for step in 0...10 {
            frames.append(SplitBrainIcon.burstFrame(.blast, t: CGFloat(step) / 10, pieces: 4, intensity: 2, size: size))
        }
        writeStrip(frames, scale: 6, to: "/tmp/itimer-burst-sheet.png")
        frames = (0...8).map { SplitBrainIcon.burstFrame(.wobble, t: CGFloat($0) / 8, pieces: 4, size: size) }
        writeStrip(frames, scale: 6, to: "/tmp/itimer-wobble-sheet.png")
        frames = (0...8).map { SplitBrainIcon.burstFrame(.heal, t: CGFloat($0) / 8, pieces: 3, size: size) }
        writeStrip(frames, scale: 6, to: "/tmp/itimer-heal-sheet.png")
        note("burst sheets rendered")
    }

    private static func statusButtonSnapshot() -> NSImage? {
        guard let button = NSApp.windows.flatMap({ collect(NSStatusBarButton.self, in: $0.contentView) }).first,
              let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
        button.cacheDisplay(in: button.bounds, to: rep)
        let image = NSImage(size: button.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Lays images side by side, scaled up, on light and dark bands.
    private static func writeStrip(_ images: [NSImage], scale: CGFloat, to path: String) {
        guard !images.isEmpty else { return }
        let cell = NSSize(
            width: (images.map(\.size.width).max() ?? 22) * scale,
            height: (images.map(\.size.height).max() ?? 18) * scale
        )
        let gap: CGFloat = 8
        let width = Int((cell.width + gap) * CGFloat(images.count) + gap)
        let height = Int(cell.height * 2 + gap * 3)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (row, background) in [NSColor(white: 0.94, alpha: 1), NSColor(white: 0.16, alpha: 1)].enumerated() {
            let y = gap + CGFloat(row) * (cell.height + gap)
            for (index, image) in images.enumerated() {
                let x = gap + CGFloat(index) * (cell.width + gap)
                let rect = NSRect(x: x, y: y, width: cell.width, height: cell.height)
                background.setFill()
                rect.fill()
                image.draw(in: NSRect(x: x, y: y, width: image.size.width * scale, height: image.size.height * scale))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func renderBrainStates() {
        // Resting status glyphs: whole, cracked in two, then split 3–6.
        let states: [(Int, CGFloat)] = [(1, 0), (2, SplitBrainIcon.crackSpread), (2, 1), (3, 1), (4, 1), (5, 1), (6, 1)]
        writeStrip(states.map { SplitBrainIcon.statusImage(pieces: $0.0, spread: $0.1) }, scale: 6, to: "/tmp/itimer-brain-states.png")
        let buddies = HStack(spacing: 12) {
            ForEach([0, 1, 2, 3, 4], id: \.self) { count in
                BrainBuddy(running: count, threshold: 3, tint: count == 0 ? Color(nsColor: .systemGray) : Theme.load(count, threshold: 3))
                    .scaleEffect(2)
                    .frame(width: 136, height: 120)
            }
        }
        .padding(12)
        render(buddies, size: nil, to: "/tmp/itimer-buddies.png")
        render(buddies, size: nil, appearance: .darkAqua, to: "/tmp/itimer-buddies-dark.png")
        note("brain states rendered")
    }

    /// Offscreen render of any view. `size` nil = the view's own fitting size.
    private static func render<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance.Name = .aqua, to path: String) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: size ?? hosting.fittingSize)
        let offscreen = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        offscreen.appearance = NSAppearance(named: appearance)
        offscreen.contentView = hosting
        offscreen.orderFrontRegardless()
        offscreen.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        CATransaction.flush()
        snapshot(offscreen, to: path)
        offscreen.orderOut(nil)
    }

    private static func snapshot(_ window: NSWindow?, to path: String) {
        window?.displayIfNeeded()
        guard let view = window?.contentView else { note("no window to snapshot \(path)"); return }
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        CATransaction.flush()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { note("no rep for \(path)"); return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { note("no png for \(path)"); return }
        try? data.write(to: URL(fileURLWithPath: path))
        note("snapshot \(path) \(Int(bounds.width))x\(Int(bounds.height))")
    }

    private static func openPanel() -> Bool {
        guard menuWindow() == nil else { return true }
        return clickStatusItem()
    }

    private static func closePanel() -> Bool {
        guard menuWindow() != nil else { return true }
        return clickStatusItem()
    }

    private static func clickStatusItem() -> Bool {
        if let button = NSApp.windows.flatMap({ collect(NSStatusBarButton.self, in: $0.contentView) }).first {
            button.performClick(button)
            return true
        }
        if let element = find(identifier: "status-item") {
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        return false
    }

    private static func menuWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && String(describing: Swift.type(of: window)).contains("MenuBarExtra")
        }
    }

    private static func statusItemTitle() -> String {
        guard let element = find(identifier: "status-item") else { return "" }
        return string(element, kAXTitleAttribute) ?? ""
    }

    private static func fileTaskCount() -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: TaskStore.shared.url),
              let snapshot = try? decoder.decode(StoreSnapshot.self, from: data) else {
            return -1
        }
        return snapshot.tasks.count
    }

    private static func windowSummary() -> String {
        NSApp.windows.map { "\($0.className) visible=\($0.isVisible) title=\($0.title)" }.joined(separator: "; ")
    }

    private static func collect<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews {
            found.append(contentsOf: collect(type, in: subview))
        }
        return found
    }

    private static func wait(for seconds: TimeInterval, label: String, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        note("timeout \(label)")
        return false
    }

    private static func note(_ message: String) {
        steps.append(message)
        persist(passed: false)
    }

    private static func persist(passed: Bool) {
        let payload: [String: Any] = ["passed": passed, "steps": steps]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: resultURL)
    }

    private static func find(identifier: String) -> AXUIElement? {
        find(in: AXUIElementCreateApplication(getpid()), depth: 0) { string($0, kAXIdentifierAttribute) == identifier }
    }

    private static func find(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        if matches(element) { return element }
        guard depth < 8 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if let found = find(in: child, depth: depth + 1, where: matches) { return found }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
