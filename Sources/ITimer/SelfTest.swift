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
            let passed: Bool
            switch launch.scenario {
            case "workflow": passed = await exerciseWorkflow()
            case "goal": passed = await exerciseGoal()
            case "record": passed = await exerciseRecordTimes()
            default: passed = await exercise()
            }
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
        let labels = ["#方案", "#生活", "#bug"]
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
            guard await captureRealPanel() else { return false }
        }
        return true
    }

    /// Snapshot the live MenuBarExtra panel with schedules, then with the
    /// composer open, plus the main window — for visual review. Also checks
    /// that context menus in both hold still while open.
    private static func captureRealPanel() async -> Bool {
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }) {
            snapshot(main, to: "/tmp/itimer-real-main.png")
        }
        _ = closePanel()
        try? await Task.sleep(nanoseconds: 600_000_000)
        // The main window keeps the store clock running (only the panel
        // pauses it), so its menus are the ones exposed to per-second ticks.
        UserDefaults.standard.set(MainDestination.tasks.raw, forKey: "mainDestination")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }) {
            guard await probeContextMenu(in: main, place: "main window") else { return false }
        }
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
        guard open, let panel = menuWindow() else { note("panel would not reopen for capture"); return true }
        snapshot(panel, to: "/tmp/itimer-real-panel.png")
        guard await probeContextMenu(in: panel, place: "panel") else { return false }
        NotificationCenter.default.post(name: .iTimerNewSchedule, object: false)
        try? await Task.sleep(nanoseconds: 700_000_000)
        snapshot(menuWindow(), to: "/tmp/itimer-real-composer.png")
        _ = closePanel()
        return true
    }

    /// Schedules never start on their own; overtime keeps counting.
    private static func exerciseSchedules() -> Bool {
        let store = TaskStore.shared
        let now = Date()
        for task in store.runningTasks { store.complete(id: task.id, at: now) }
        guard let due = store.addSchedule(title: "周会 #会议", start: now.addingTimeInterval(-600), plannedDuration: 3600, reminderLead: 0),
              store.addSchedule(title: "写周报 #汇报", start: now.addingTimeInterval(7200), plannedDuration: 7200, reminderLead: 600) != nil,
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
        var draft = ScheduleDraft.new(title: "准备季度汇报 #汇报 #PPT", asOf: now)
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
        guard let child = store.addSubtask(parentID: review.id, title: "看完鉴权模块") else {
            note("subtask failed")
            return false
        }
        // The row's "add subtask" field: undated, and shown in the parent's
        // progress count.
        guard let step = store.addSchedule(title: "补单测 #测试", parentID: review.id, start: nil, plannedDuration: nil, reminderLead: nil),
              step.isUndated, step.parentID == review.id, step.tags == ["测试"],
              store.subtasks(of: review.id).count == 2 else {
            note("subtask from the row field failed")
            return false
        }
        // Folding the parent hides its subtasks; the flag lives in the app's
        // defaults, so put the user's back after.
        let defaults = UserDefaults.standard
        let savedFolds = defaults.string(forKey: "collapsedParents")
        defer { defaults.set(savedFolds, forKey: "collapsedParents") }
        defaults.set("", forKey: "collapsedParents")
        let unfolded = renderedLabels(MenuBarView(store: store), size: NSSize(width: 380, height: 760), to: "/tmp/itimer-subtasks-popup.png")
        // The undated subtask sits under its running parent, not down in
        // 时间待定: no section title between the parent and it.
        guard let parentAt = unfolded.firstIndex(where: { $0.contains("代码评审") }),
              let stepAt = unfolded.firstIndex(where: { $0.contains("补单测") }),
              unfolded.contains(where: { $0.contains(child.title) }),
              parentAt < stepAt,
              !unfolded[parentAt..<stepAt].contains(where: { ["已暂停", "接下来", "时间待定"].contains($0) }) else {
            note("subtasks did not nest under their parent")
            return false
        }
        note("subtasks nest under their parent")
        defaults.set(review.id.uuidString, forKey: "collapsedParents")
        let folded = renderedLabels(MenuBarView(store: store), size: NSSize(width: 380, height: 760), to: "/tmp/itimer-subtasks-folded.png")
        guard !folded.contains(where: { $0.contains(child.title) }),
              folded.contains(where: { $0.contains("代码评审") }),
              folded.contains("展开子任务") else {
            note("folding subtasks failed")
            return false
        }
        note("parents fold their subtasks")
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

    /// Texts and labels a view puts in the accessibility tree, read from
    /// an offscreen window (optionally snapshotted too).
    private static func renderedLabels<V: View>(_ view: V, size: NSSize, to path: String? = nil) -> [String] {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let offscreen = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        offscreen.contentView = hosting
        offscreen.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        if let path { snapshot(offscreen, to: path) }
        var labels: [String] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 40, let element = element as? NSObject else { return }
            for key in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"]
            where element.responds(to: NSSelectorFromString(key)) {
                if let text = element.value(forKey: key) as? String, !text.isEmpty { labels.append(text) }
            }
            guard element.responds(to: NSSelectorFromString("accessibilityChildren")) else { return }
            for child in (element.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(hosting, depth: 0)
        offscreen.orderOut(nil)
        return labels
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

    /// Tallies from an open context menu. Touched on the main thread only
    /// (menu notifications and the timers run there).
    private final class MenuProbe: @unchecked Sendable {
        var openedAt: Date?
        var closed = false
        /// Item changes after the menu finished building: each is a flash.
        var rebuilds = 0
        var menu: NSMenu?
    }

    /// Right-clicks the first open task row in `window`, holds the menu open
    /// for a few seconds and fails if its items get rebuilt meanwhile (the
    /// menu visibly flashes). Skipped, not failed, when no row is reachable.
    private static func probeContextMenu(in window: NSWindow, place: String) async -> Bool {
        // Rows are only reachable through accessibility while the app is active.
        for _ in 1...10 where !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let open = TaskStore.shared.tasks.filter { !$0.isCompleted }
        let row = open.lazy.compactMap { find(identifier: "task-row-\($0.id.uuidString)") }.compactMap(screenCenter(of:)).first(where: window.frame.contains)
        // Otherwise aim where the list's first rows sit (under the hero card);
        // any row menu there shows the same flash.
        // In the main window the 任务 page is centered right of the rail.
        let sidebar = collect(NSSplitView.self, in: window.contentView).first?.arrangedSubviews.first?.frame.width ?? 0
        let point = row ?? (window === menuWindow()
            ? NSPoint(x: window.frame.midX, y: window.frame.maxY - 310)
            : NSPoint(x: window.frame.minX + sidebar + (window.frame.width - sidebar) / 2, y: window.frame.maxY - 350))
        let probe = MenuProbe()
        let center = NotificationCenter.default
        var observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                guard probe.menu == nil else { return }
                probe.menu = note.object as? NSMenu
                probe.openedAt = Date()
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
                if note.object as? NSMenu === probe.menu { probe.closed = true }
            },
        ]
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                guard let openedAt = probe.openedAt, !probe.closed, Date().timeIntervalSince(openedAt) > 0.5 else { return }
                probe.rebuilds += 1
            })
        }
        defer { observers.forEach(center.removeObserver) }
        // Long enough for several clock ticks. Tracking blocks this task's
        // actor, so both the click and the close come from run-loop timers:
        // a click sent from inside this task would also stall the app clock
        // (a main-actor job) and hide exactly the rebuilds being probed.
        let closer = Timer(timeInterval: 3.5, repeats: false) { _ in probe.menu?.cancelTracking() }
        RunLoop.main.add(closer, forMode: .common)
        guard let click = NSEvent.mouseEvent(
            with: .rightMouseDown, location: window.convertPoint(fromScreen: point), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return true }
        nonisolated(unsafe) let event = click
        RunLoop.main.add(Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { window.sendEvent(event) }
        }, forMode: .common)
        try? await Task.sleep(nanoseconds: 4_200_000_000)
        guard probe.menu != nil else {
            closer.invalidate()
            note("menu probe (\(place)): menu did not open, skipped")
            return true
        }
        guard probe.rebuilds == 0 else {
            note("context menu (\(place)) rebuilt \(probe.rebuilds) items while open — it flashes")
            return false
        }
        note("context menu (\(place)) held still while open")
        return true
    }

    /// Screen point (AppKit, bottom-left origin) at the element's center.
    private static func screenCenter(of element: AXUIElement) -> NSPoint? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: origin.x + extent.width / 2, y: top - (origin.y + extent.height / 2))
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

    /// The field editor holding `name`, when a text field has keyboard
    /// focus with that text in it.
    private static func editingField(named name: String) -> NSTextView? {
        NSApp.windows.lazy.compactMap { $0.firstResponder as? NSTextView }.first { $0.string == name }
    }

    /// Rows of a list sit deeper than most controls; pass a larger depth.
    private static func find(identifier: String, depth limit: Int = 8) -> AXUIElement? {
        find(in: AXUIElementCreateApplication(getpid()), depth: 0, limit: limit) { string($0, kAXIdentifierAttribute) == identifier }
    }

    private static func find(in element: AXUIElement, depth: Int, limit: Int = 8, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        if matches(element) { return element }
        guard depth < limit else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if let found = find(in: child, depth: depth + 1, limit: limit, where: matches) { return found }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

// MARK: - Completed record editor

extension SelfTest {
    /// Real entry points, native date fields and button actions. Window
    /// events also work in background mode, without moving the user's mouse.
    static func exerciseRecordTimes() async -> Bool {
        let store = TaskStore.shared
        let end = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60)
        let start = end.addingTimeInterval(-7200)
        guard let task = store.addTask(title: "忘记结束的记录 #自检", at: start) else { return false }
        store.pause(id: task.id, at: start.addingTimeInterval(1200))
        store.resume(id: task.id, at: start.addingTimeInterval(1800))
        store.complete(id: task.id, at: end)
        let original = store.tasks.first { $0.id == task.id }!
        let file = try? Data(contentsOf: store.url)

        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }.forEach { $0.orderOut(nil) }
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 420, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "iTimer 记录时间自检"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: MenuBarView(store: store, embedded: true, filter: .doneToday).background(Theme.canvas))
        await activateUnlessBackground()
        bringForward(window)
        defer { window.orderOut(nil) }

        func changeDate(from old: Date, to new: Date, in view: NSView?) -> Bool {
            guard let picker = collect(NSDatePicker.self, in: view).first(where: { abs($0.dateValue.timeIntervalSince(old)) < 1 }),
                  let action = picker.action else { note("native date field missing"); return false }
            picker.dateValue = new
            return NSApp.sendAction(action, to: picker.target, from: picker)
        }
        func saveButton(in view: NSView?) -> NSButton? {
            collect(NSButton.self, in: view).first
        }
        // The fixed test window puts the first completed row below the hero.
        let editPoint = NSPoint(x: 352, y: 386)
        try? await Task.sleep(for: .milliseconds(500))
        await click(in: window, at: editPoint)
        guard await wait(for: 3, label: "inline date fields", until: {
            collect(NSDatePicker.self, in: window.contentView).count == 4
        }) else {
            snapshot(window, to: "/tmp/itimer-record-time-failure.png")
            return false
        }
        snapshot(window, to: "/tmp/itimer-record-time-inline.png")
        window.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(100))
        snapshot(window, to: "/tmp/itimer-record-time-inline-dark.png")
        window.appearance = NSAppearance(named: .aqua)
        guard changeDate(from: end, to: start.addingTimeInterval(-60), in: window.contentView),
              await wait(for: 3, label: "invalid time disables Save", until: {
                  saveButton(in: window.contentView)?.isEnabled == false
              }),
              store.tasks.first(where: { $0.id == task.id }) == original else { return false }
        await click(in: window, at: NSPoint(x: 388, y: 584))
        guard await wait(for: 3, label: "cancel", until: { collect(NSDatePicker.self, in: window.contentView).isEmpty }),
              store.tasks.first(where: { $0.id == task.id }) == original,
              (try? Data(contentsOf: store.url)) == file else {
            note("cancel changed the record")
            return false
        }
        note("completed row opens all segments; invalid time disables Save; Cancel keeps original data")

        let correctedEnd = start.addingTimeInterval(3600)
        await click(in: window, at: editPoint)
        guard await wait(for: 3, label: "reopened editor", until: { collect(NSDatePicker.self, in: window.contentView).count == 4 }),
              changeDate(from: end, to: correctedEnd, in: window.contentView),
              await wait(for: 3, label: "valid Save", until: { saveButton(in: window.contentView)?.isEnabled == true }),
              let save = saveButton(in: window.contentView) else { return false }
        save.performClick(nil)
        guard await wait(for: 3, label: "saved timing", until: {
            collect(NSDatePicker.self, in: window.contentView).isEmpty && store.tasks.first { $0.id == task.id }?.segments.last?.endedAt == correctedEnd
        }), let edited = store.tasks.first(where: { $0.id == task.id }),
              edited.segments.first == original.segments.first,
              edited.duration(asOf: Date()) == 3000,
              TaskStore(url: store.url).tasks == store.tasks else {
            note("corrected timing did not persist or lost the pause")
            return false
        }
        note("native end field saved correction; pause and first segment retained; reload matches")

        window.contentView = NSHostingView(rootView: AnalysisView(store: store, range: .all))
        window.setContentSize(NSSize(width: 1100, height: 760))
        try? await Task.sleep(for: .milliseconds(500))
        guard let scrollView = collect(NSScrollView.self, in: window.contentView).first,
              let document = scrollView.documentView else { note("analysis scroll view missing"); return false }
        let bottom = document.isFlipped ? max(0, document.bounds.height - scrollView.contentView.bounds.height) : 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try? await Task.sleep(for: .milliseconds(200))
        snapshot(window, to: "/tmp/itimer-record-time-analysis.png")
        // The one record sits above the rules at the bottom of this fixed window.
        await click(in: window, at: NSPoint(x: 1018, y: 98))
        guard await wait(for: 3, label: "analysis sheet", until: {
            window.sheets.first.map { collect(NSDatePicker.self, in: $0.contentView).count == 4 } ?? false
        }), let sheet = window.sheets.first else { return false }
        snapshot(sheet, to: "/tmp/itimer-record-time-sheet.png")
        let shiftedStart = start.addingTimeInterval(60)
        guard changeDate(from: start, to: shiftedStart, in: sheet.contentView),
              let save = saveButton(in: sheet.contentView) else { return false }
        save.performClick(nil)
        guard await wait(for: 3, label: "sheet saved", until: {
            window.sheets.isEmpty && store.tasks.first { $0.id == task.id }?.segments.first?.startedAt == shiftedStart
        }), store.report(range: .all).tasks.first(where: { $0.id == task.id })?.duration == 2940 else {
            note("analysis sheet did not update the start or report")
            return false
        }
        note("analysis record opens a sheet; native start field saves and analysis recalculates")
        return true
    }
}

// MARK: - Workflow canvas

extension SelfTest {
    /// Drives the workflow canvas with mouse and key events sent through its
    /// window, the way real input arrives: wire two cards from a port, move
    /// a card, pan, scroll, delete a selected card, and type a new step.
    static func exerciseWorkflow() async -> Bool {
        let store = TaskStore.shared
        guard let flow = store.addWorkflow("自检流程") else {
            note("workflow not created")
            return false
        }
        // A known viewport maps canvas points 1:1 onto the view, offset by it.
        var origin = CGSize(width: 160, height: 160)
        store.setViewport(id: flow.id, WorkflowViewport(x: origin.width, y: origin.height, scale: 1))
        guard let first = store.addWorkflowStep(title: "甲", in: flow.id, x: 0, y: 0),
              let second = store.addWorkflowStep(title: "乙", in: flow.id, x: 336, y: 0),
              let third = store.addWorkflowStep(title: "丙", in: flow.id, x: 0, y: 192) else {
            note("steps not created")
            return false
        }
        UserDefaults.standard.set(MainDestination.workflow(flow.id).raw, forKey: "mainDestination")
        await activateUnlessBackground()
        guard await wait(for: 5, label: "canvas", until: { canvasCatcher() != nil }),
              let catcher = canvasCatcher(), let window = catcher.window else {
            note("canvas not shown. windows=\(windowSummary())")
            return false
        }
        bringForward(window)
        try? await Task.sleep(nanoseconds: 800_000_000)
        func spot(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            catcher.convert(NSPoint(x: x + origin.width, y: y + origin.height), to: nil)
        }
        let half = CanvasMetrics.card.width / 2
        let nodes = { store.workflow(id: flow.id)?.nodes ?? [] }
        let edges = { store.workflow(id: flow.id)?.edges ?? [] }

        await drag(in: window, from: spot(half + 7, 0), to: spot(336, 0))
        guard await wait(for: 2, label: "link", until: { edges() == [WorkflowEdge(from: first.id, to: second.id)] }) else {
            note("dragging 甲's port onto 乙 did not wire them: \(edges())")
            return false
        }
        note("port drag wired 甲 → 乙")

        await drag(in: window, from: spot(40, 200), to: spot(136, 272))
        guard await wait(for: 2, label: "move", until: {
            nodes().first { $0.taskID == third.id }.map { $0.x == 96 && $0.y == 264 } ?? false
        }) else {
            note("card drag did not land 丙 on (96, 264): \(String(describing: nodes().first { $0.taskID == third.id }))")
            return false
        }
        note("card drag moved 丙 onto the half grid")

        await drag(in: window, from: spot(480, 420), to: spot(380, 370))
        guard await wait(for: 3, label: "pan", until: {
            store.workflow(id: flow.id)?.viewport == WorkflowViewport(x: 60, y: 110, scale: 1)
        }) else {
            note("background drag did not pan: \(String(describing: store.workflow(id: flow.id)?.viewport))")
            return false
        }
        origin = CGSize(width: 60, height: 110)
        note("background drag panned and the viewport was saved")

        if await scroll(in: window, at: spot(500, 300), dy: -40) {
            guard await wait(for: 3, label: "scroll", until: {
                store.workflow(id: flow.id)?.viewport == WorkflowViewport(x: 60, y: 70, scale: 1)
            }) else {
                note("scroll did not pan: \(String(describing: store.workflow(id: flow.id)?.viewport))")
                return false
            }
            origin = CGSize(width: 60, height: 70)
            note("scroll wheel panned")
        }

        await click(in: window, at: spot(336 + 40, 8))
        await key(in: window, characters: "\u{7F}", code: 51)
        guard await wait(for: 2, label: "delete", until: {
            !nodes().contains { $0.taskID == second.id } && edges().isEmpty
        }) else {
            note("Delete did not take 乙 off the canvas: nodes=\(nodes().count) edges=\(edges().count)")
            return false
        }
        guard store.tasks.contains(where: { $0.id == second.id }) else {
            note("Delete removed the task itself, not just the card")
            return false
        }
        note("Delete took the selected card off, task kept")

        await click(in: window, at: spot(480, 300), count: 2)
        guard await wait(for: 2, label: "composer", until: { window.firstResponder is NSTextView }),
              let editor = window.firstResponder as? NSTextView else {
            note("double-click did not open a focused step field: \(String(describing: window.firstResponder))")
            return false
        }
        editor.insertText("丁 #自检x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = nodes().count
        await key(in: window, characters: "\u{7F}", code: 51)
        guard editor.string == "丁 #自检", nodes().count == before else {
            note("Delete in the step field did not stay in the field: text=\(editor.string) nodes=\(nodes().count)")
            return false
        }
        await key(in: window, characters: "\r", code: 36)
        guard await wait(for: 2, label: "new step", until: {
            store.tasks.contains { $0.title == "丁" && $0.tags == ["自检"] && store.workflow(containing: $0.id)?.id == flow.id }
        }) else {
            note("typing in the step field did not add 丁")
            return false
        }
        await key(in: window, characters: "\u{1B}", code: 53)
        note("double-click + typing added 丁 to the canvas")
        snapshot(window, to: "/tmp/itimer-workflow.png")
        return true
    }

    /// Drives a goal's roadmap the way a person would: wire two milestones
    /// from a port, open one and come back, mark it reached, then use the
    /// 目标 menu with the main window closed.
    static func exerciseGoal() async -> Bool {
        let store = TaskStore.shared
        guard let goal = store.addGoal("自检目标") else {
            note("goal not created")
            return false
        }
        store.setGoalViewport(id: goal.id, WorkflowViewport(x: 160, y: 160, scale: 1))
        let gap = CGFloat(Goal.columnGap)
        guard let first = store.addMilestone(title: "内测", in: goal.id, x: 0, y: 0),
              let second = store.addMilestone(title: "首批付费", in: goal.id, x: Double(gap), y: 0),
              let step = store.addWorkflowStep(title: "招募内测用户", in: first.id, x: 0, y: 0) else {
            note("milestones not created")
            return false
        }
        UserDefaults.standard.set(MainDestination.goal(goal.id).raw, forKey: "mainDestination")
        await activateUnlessBackground()
        guard await wait(for: 5, label: "roadmap", until: { find(identifier: "goal-title") != nil && canvasCatcher() != nil }),
              let catcher = canvasCatcher(), let window = catcher.window else {
            note("roadmap not shown. windows=\(windowSummary())")
            return false
        }
        bringForward(window)
        try? await Task.sleep(nanoseconds: 800_000_000)
        // The canvas may pan once it knows its size; map from where it settled.
        let viewport = store.goal(id: goal.id)?.viewport ?? WorkflowViewport(x: 160, y: 160, scale: 1)
        func spot(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            catcher.convert(NSPoint(x: x * viewport.scale + viewport.x, y: y * viewport.scale + viewport.y), to: nil)
        }
        let card = CanvasLayout.goal.card
        let edges = { store.goal(id: goal.id)?.edges ?? [] }
        let states = { store.milestoneSummaries(in: goal.id).mapValues(\.state) }

        guard states()[second.id] == .ready else {
            note("unwired 首批付费 should be ready: \(String(describing: states()[second.id]))")
            return false
        }
        await drag(in: window, from: spot(card.width / 2 + 7, 0), to: spot(gap, 0))
        guard await wait(for: 3, label: "milestone link", until: { edges() == [WorkflowEdge(from: first.id, to: second.id)] }) else {
            note("dragging 内测's port onto 首批付费 did not wire them: \(edges())")
            return false
        }
        guard await wait(for: 3, label: "blocked", until: { states()[second.id] == .blocked }) else {
            note("首批付费 did not wait on 内测: \(String(describing: states()[second.id]))")
            return false
        }
        note("port drag wired 内测 → 首批付费, which now waits")

        await click(in: window, at: spot(-card.width / 2 + 40, card.height / 2 - 14), count: 2)
        guard await wait(for: 3, label: "open milestone", until: {
            UserDefaults.standard.string(forKey: "mainDestination") == MainDestination.workflow(first.id).raw
                && find(identifier: "back-to-roadmap") != nil
        }) else {
            note("double-clicking 内测 did not open its workflow: \(UserDefaults.standard.string(forKey: "mainDestination") ?? "nil")")
            return false
        }
        guard let back = find(identifier: "back-to-roadmap"),
              AXUIElementPerformAction(back, kAXPressAction as CFString) == .success,
              await wait(for: 3, label: "back", until: {
                  UserDefaults.standard.string(forKey: "mainDestination") == MainDestination.goal(goal.id).raw
              }) else {
            note("返回路线图 did not bring the roadmap back")
            return false
        }
        note("double-click opened 内测's workflow; 返回路线图 came back")

        store.complete(id: step.id)
        guard await wait(for: 2, label: "review", until: { states()[first.id] == .review }),
              await wait(for: 3, label: "achieve button", until: { find(identifier: "milestone-achieve-\(first.id.uuidString)") != nil }),
              let achieve = find(identifier: "milestone-achieve-\(first.id.uuidString)"),
              AXUIElementPerformAction(achieve, kAXPressAction as CFString) == .success else {
            note("内测 with its tasks done offered no 标记达成: \(String(describing: states()[first.id]))")
            return false
        }
        guard await wait(for: 2, label: "achieved", until: {
            states()[first.id] == .achieved && states()[second.id] == .ready
        }) else {
            note("marking 内测 reached did not free 首批付费: \(states())")
            return false
        }
        note("标记达成 reached 内测 and 首批付费 became ready")
        snapshot(window, to: "/tmp/itimer-goal.png")

        guard await exerciseRail(in: window, goal: goal) else { return false }

        window.close()
        guard await wait(for: 2, label: "window closed", until: { !window.isVisible }) else {
            note("main window did not close")
            return false
        }
        UserDefaults.standard.set(MainDestination.analysis.raw, forKey: "mainDestination")
        guard pressMenuItem(menu: "目标", item: goal.name),
              await wait(for: 3, label: "menu reopen", until: {
                  UserDefaults.standard.string(forKey: "mainDestination") == MainDestination.goal(goal.id).raw
                      && find(identifier: "goal-title") != nil
              }) else {
            note("目标 › \(goal.name) did not reopen the roadmap")
            return false
        }
        note("目标 menu reopened the closed window on the roadmap")

        let count = store.goals.count
        guard pressMenuItem(menu: "目标", item: "新建目标"),
              await wait(for: 3, label: "new goal", until: { store.goals.count == count + 1 }),
              let made = store.goals.last,
              await wait(for: 3, label: "goal rename", until: { editingField(named: made.name) != nil }) else {
            let editing = NSApp.windows.compactMap { ($0.firstResponder as? NSTextView)?.string }
            note("新建目标 did not add a goal waiting for its name: goals=\(store.goals.count - count) editing=\(editing)")
            return false
        }
        note("新建目标 added a goal with its name field open")
        return true
    }

    /// Off in a background run: the app never becomes active, so the user
    /// keeps the screen, the keyboard and the mouse. Events still reach the
    /// windows, which get them directly.
    private static var background: Bool { DebugLaunchFile.current?.background == true }

    private static func activateUnlessBackground() async {
        guard !background else { return }
        for _ in 1...10 where !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func bringForward(_ window: NSWindow) {
        if background {
            // Key without activating the app: the window then takes clicks
            // as a front window does, while another app keeps the screen.
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The rail switches modules and brings 目标 back to the roadmap it
    /// left; 任务 lists by status or tag; folding the list narrows the
    /// sidebar to the rail, which stays.
    private static func exerciseRail(in window: NSWindow, goal: Goal) async -> Bool {
        let defaults = UserDefaults.standard
        let destination = { defaults.string(forKey: "mainDestination") }
        func sidebarWidth() -> CGFloat {
            collect(NSSplitView.self, in: window.contentView).first?.arrangedSubviews.first?.frame.width ?? 0
        }
        let onlyRail = { abs(sidebarWidth() - MainRail.width) < 2 }
        let goalRow = "sidebar-goal-\(goal.id.uuidString)"
        guard pressElement("rail-tasks"),
              await wait(for: 3, label: "tasks module", until: {
                  destination() == MainDestination.tasks.raw
                      && find(identifier: "new-task-field") != nil && find(identifier: "goal-title") == nil
              }),
              await wait(for: 2, label: "task lists", until: {
                  sidebarWidth() > 200 && find(identifier: "task-filter-all", depth: 20) != nil
              }) else {
            note("rail 任务 did not show the task list with its lists: \(destination() ?? "nil") width=\(sidebarWidth())")
            return false
        }
        defaults.set(TaskFilter.doneToday.raw, forKey: "taskFilter")
        guard await wait(for: 2, label: "filter", until: { window.title == "任务 › 今日完成" }) else {
            note("picking 今日完成 did not filter the page: title=\(window.title)")
            return false
        }
        snapshot(window, to: "/tmp/itimer-layout-tasks.png")
        defaults.set(TaskFilter.all.raw, forKey: "taskFilter")
        note("rail 任务 showed the task list beside its status and tag lists")

        guard pressElement("list-panel-toggle"),
              await wait(for: 3, label: "list folded", until: {
                  onlyRail() && find(identifier: "task-filter-all", depth: 20) == nil
              }),
              find(identifier: "rail-tasks") != nil, find(identifier: "new-task-field") != nil else {
            note("folding the list did not leave just the rail: width=\(sidebarWidth())")
            return false
        }
        snapshot(window, to: "/tmp/itimer-layout-collapsed.png")
        guard pressElement("rail-analysis"),
              await wait(for: 3, label: "analysis", until: { destination() == MainDestination.analysis.raw && onlyRail() }) else {
            note("rail 分析 did not show the analysis beside the bare rail: width=\(sidebarWidth())")
            return false
        }
        note("list folded to the rail; 分析 has none")

        guard pressElement("rail-goals"),
              await wait(for: 3, label: "goals module", until: {
                  destination() == MainDestination.goal(goal.id).raw && find(identifier: "goal-title") != nil
              }),
              pressElement("list-panel-toggle"),
              await wait(for: 3, label: "list unfolded", until: {
                  sidebarWidth() > 200 && find(identifier: goalRow, depth: 20) != nil
              }) else {
            note("rail 目标 did not return to the roadmap, or its list did not unfold: \(destination() ?? "nil") width=\(sidebarWidth())")
            return false
        }
        snapshot(window, to: "/tmp/itimer-layout-expanded.png")
        note("rail 目标 returned to the roadmap it left; the list unfolded beside the rail")
        return true
    }

    private static func pressElement(_ identifier: String) -> Bool {
        guard let element = find(identifier: identifier) else {
            note("no \(identifier)")
            return false
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Presses an item of a menu bar menu through accessibility. SwiftUI
    /// fills a CommandMenu only when it opens, so the menu is updated first.
    private static func pressMenuItem(menu title: String, item: String) -> Bool {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu else {
            note("no \(title) menu")
            return false
        }
        menu.update()
        guard let index = menu.items.firstIndex(where: { $0.title == item }) else {
            note("no \(item) in \(title): \(menu.items.map(\.title))")
            return false
        }
        menu.performActionForItem(at: index)
        return true
    }

    private static func canvasCatcher() -> CanvasEventCatcher.CatcherView? {
        NSApp.windows.flatMap { collect(CanvasEventCatcher.CatcherView.self, in: $0.contentView) }.first
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private static func drag(in window: NSWindow, from: NSPoint, to: NSPoint, steps: Int = 10) async {
        var events = [mouse(.leftMouseDown, at: from, in: window)]
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            events.append(mouse(.leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), in: window))
        }
        events.append(mouse(.leftMouseUp, at: to, in: window))
        await play(events.compactMap { $0 }, in: window)
    }

    private static func click(in window: NSWindow, at point: NSPoint, count: Int = 1) async {
        var events: [NSEvent?] = []
        for clicks in 1...count {
            events.append(mouse(.leftMouseDown, at: point, in: window, clicks: clicks))
            events.append(mouse(.leftMouseUp, at: point, in: window, clicks: clicks))
        }
        await play(events.compactMap { $0 }, in: window)
    }

    private static func key(in window: NSWindow, characters: String, code: UInt16) async {
        let events = [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            )
        }
        await play(events, in: window)
    }

    /// Hands an event to its view directly. A window of an app that is not
    /// active is never key, and AppKit spends the first click on such a
    /// window bringing it forward; the background run skips that.
    private static func deliver(_ event: NSEvent, in window: NSWindow, pressed: inout NSView?) {
        switch event.type {
        case .leftMouseDown:
            guard let frame = window.contentView?.superview,
                  let view = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return }
            pressed = view
            view.mouseDown(with: event)
        case .leftMouseDragged:
            pressed?.mouseDragged(with: event)
        case .leftMouseUp:
            pressed?.mouseUp(with: event)
            pressed = nil
        default:
            window.sendEvent(event)
        }
    }

    /// Queues a pixel scroll at a window point, where the canvas's event
    /// monitor watches. False when no event could be made.
    private static func scroll(in window: NSWindow, at point: NSPoint, dy: Int32) async -> Bool {
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else {
            note("scroll event unavailable; skipped")
            return false
        }
        let screen = window.convertPoint(toScreen: point)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cgEvent.location = CGPoint(x: screen.x, y: top - screen.y)
        guard let event = NSEvent(cgEvent: cgEvent) else {
            note("scroll event unavailable; skipped")
            return false
        }
        if background {
            // Local monitors see what the app dispatches; a window behind
            // another app's is not found by screen position, so hand the
            // event to the canvas's monitor directly.
            guard let catcher = collect(CanvasEventCatcher.CatcherView.self, in: window.contentView).first,
                  catcher.deliver(event, at: catcher.convert(point, from: nil)) else {
                note("scroll event not taken by the canvas; skipped")
                return false
            }
        } else {
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return true
    }

    /// Sends each event through the window from a timer: a mouse-down may
    /// start a tracking loop, which would hold up this task until release.
    private static func play(_ events: [NSEvent], in window: NSWindow, gap: TimeInterval = 0.04) async {
        // The view that took the mouse-down gets the drags and the release,
        // as AppKit does.
        nonisolated(unsafe) var pressed: NSView?
        for (index, event) in events.enumerated() {
            nonisolated(unsafe) let event = event
            RunLoop.main.add(Timer(timeInterval: gap * Double(index + 1), repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard background else { return window.sendEvent(event) }
                    deliver(event, in: window, pressed: &pressed)
                }
            }, forMode: .common)
        }
        try? await Task.sleep(nanoseconds: UInt64((gap * Double(events.count + 2) + 0.35) * 1_000_000_000))
    }
}
