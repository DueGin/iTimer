import AppKit
import ITimerCore
import SwiftUI

/// Brings up the main window from anywhere: the menu bar panel, the
/// 目标 menu, a notification.
@MainActor
enum MainWindow {
    static func reveal(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        // A background self-test must not take the screen from the user.
        guard DebugLaunchFile.current?.background != true else {
            openWindow(id: "main")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Unfolds the main window's sidebar if it was folded away, so a row
    /// waiting for its name is on screen. Folding is AppKit's own state
    /// (it is what the window restores), so it is changed there.
    static func showSidebar() {
        for window in NSApp.windows {
            guard let split = firstSplitView(in: window.contentView),
                  let controller = split.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }),
                  sidebar.isCollapsed else { continue }
            sidebar.isCollapsed = false
        }
    }

    private static func firstSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = firstSplitView(in: subview) { return found }
        }
        return nil
    }
}

/// Requests made outside the sidebar that the sidebar carries out once it
/// is on screen — e.g. naming a goal just created from the menu bar menu.
@MainActor
@Observable
final class MainRouter {
    static let shared = MainRouter()

    enum Rename: Equatable {
        case goal(UUID)
        case workflow(UUID)
    }

    var pendingRename: Rename?
}
