import Foundation

public enum CalendarAvailability: Equatable, Sendable {
    case granted(String)
    case notDetermined
    case denied
}

/// Writes task time ranges into the user's local calendar. The real
/// implementation is EventKit; tests use a recorder.
@MainActor
public protocol TaskCalendarSyncing: AnyObject {
    var availability: CalendarAvailability { get }
    /// Create or update the event for this task; returns the event identifier.
    func upsert(task: TaskItem, asOf now: Date) -> String?
    func remove(eventID: String)
    /// Ask the system for write access.
    func requestAccess() async -> Bool
}
