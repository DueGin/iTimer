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
    /// Create (eventID nil) or update one of this task's events so it covers
    /// `range`; returns the event identifier, nil on failure.
    func upsert(task: TaskItem, range: DateInterval, eventID: String?) -> String?
    func remove(eventID: String)
    /// Ask the system for write access.
    func requestAccess() async -> Bool
}
