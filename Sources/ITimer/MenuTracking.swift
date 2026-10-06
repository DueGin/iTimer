import AppKit

/// Whether one of this app's pop-up menus (a context menu or its submenus)
/// is on screen. Re-rendering a view while its SwiftUI context menu is open
/// rebuilds the menu's items, which reads as the menu flashing; clocks and
/// hover effects hold still while this is true.
@MainActor
enum MenuTracking {
    static var isOpen: Bool {
        NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            let name = String(describing: type(of: window))
            return name.contains("MenuWindow") && !name.contains("MenuBarExtra")
        }
    }
}
