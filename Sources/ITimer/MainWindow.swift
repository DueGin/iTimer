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

    /// The split view's remembered layout from before the rail (three
    /// columns, sidebar possibly folded away) would restore the new one
    /// wrong. Dropped once, before the window comes up.
    static func forgetOldLayout() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "layoutVersion") < 2 else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSSplitView Subview Frames main") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(2, forKey: "layoutVersion")
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
