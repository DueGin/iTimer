import ITimerCore
import SwiftUI

/// The main window's left edge: one icon per module, settings at the
/// bottom. Always on screen — folding the list panel leaves it in place.
struct MainRail: View {
    var store: TaskStore
    var module: MainModule
    var select: (MainModule) -> Void

    /// Wide enough for the window's close / minimize / zoom buttons, so
    /// the sidebar keeps running up under the title bar.
    static let width: CGFloat = 76

    var body: some View {
        VStack(spacing: 6) {
            ForEach(MainModule.allCases, id: \.self) { entry in
                railButton(entry)
            }
            Spacer(minLength: 12)
            SettingsLink {
                icon("gearshape", selected: false)
            }
            .buttonStyle(railStyle(selected: false))
            .help("设置（⌘,）")
            .accessibilityLabel("设置")
            .accessibilityIdentifier("rail-settings")
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    private func railButton(_ entry: MainModule) -> some View {
        let selected = entry == module
        return Button { select(entry) } label: {
            icon(entry.systemImage, selected: selected)
                .overlay(alignment: .topTrailing) { badge(entry) }
        }
        .buttonStyle(railStyle(selected: selected))
        .keyboardShortcut(entry.shortcut, modifiers: .command)
        .help("\(entry.title)（⌘\(MainModule.allCases.firstIndex(of: entry).map { $0 + 1 } ?? 1)）")
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("rail-\(entry.rawValue)")
    }

    private func icon(_ systemImage: String, selected: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.focused : Color.secondary)
            .frame(width: 38, height: 38)
    }

    private func railStyle(selected: Bool) -> HoverButtonStyle {
        HoverButtonStyle(
            shape: .rounded,
            tint: selected ? Theme.focused : .primary,
            rest: selected ? 0.14 : 0,
            hover: selected ? 0.18 : 0.08,
            hoverForeground: selected ? nil : .primary
        )
    }

    /// Something there wants attention: a task timing, milestones waiting
    /// for 标记达成.
    @ViewBuilder
    private func badge(_ entry: MainModule) -> some View {
        switch entry {
        case .tasks:
            if store.runningCount > 0 {
                PulseDot(color: Theme.focused, active: true, size: 7)
                    .offset(x: -5, y: 5)
                    .help("有任务正在计时")
            }
        case .goals:
            let review = store.goals.reduce(0) { sum, goal in
                sum + store.milestoneSummaries(in: goal.id).values.filter { $0.state == .review }.count
            }
            if review > 0 {
                Text("\(review)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Color.orange, in: Capsule())
                    .offset(x: -1, y: 1)
                    .help("\(review) 个里程碑的任务都做完了，等你确认达成")
            }
        case .workflows:
            let tasks = store.tasksByID
            if store.standaloneWorkflows.contains(where: { flow in flow.nodes.contains { tasks[$0.taskID]?.isRunning == true } }) {
                PulseDot(color: Theme.focused, active: true, size: 7)
                    .offset(x: -5, y: 5)
                    .help("有工作流步骤正在计时")
            }
        case .analysis:
            EmptyView()
        }
    }
}
