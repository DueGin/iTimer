import AppKit
import EventKit
import ITimerCore

@MainActor
final class EventKitSync: TaskCalendarSyncing {
    private let eventStore = EKEventStore()
    private var calendar: EKCalendar?

    var availability: CalendarAvailability {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .granted("iTimer")
        case .denied, .restricted, .writeOnly:
            return .denied
        default:
            return .notDetermined
        }
    }

    func requestAccess() async -> Bool {
        if case .granted = availability { return true }
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func upsert(task: TaskItem, range: DateInterval, eventID: String?) -> String? {
        guard let target = targetCalendar() else { return nil }
        let event: EKEvent
        if let eventID, let existing = eventStore.event(withIdentifier: eventID) {
            event = existing
        } else {
            event = EKEvent(eventStore: eventStore)
            event.calendar = target
        }
        let labels = (task.category.map { ["@\($0)"] } ?? []) + task.tags.map { "#\($0)" }
        let tagLine = labels.isEmpty ? "" : labels.joined(separator: " ") + "\n"
        let planLine = task.plannedDuration.map { "预计 \(DurationFormat.prose($0))\n" } ?? ""
        let notes = tagLine + planLine + "iTimer"
        // The running refresh re-pushes every range each minute; skip the
        // write when this one (e.g. an earlier, closed stretch) is unchanged.
        if event.eventIdentifier != nil, event.title == task.title, event.startDate == range.start,
           event.endDate == range.end, event.notes == notes {
            return event.eventIdentifier
        }
        event.title = task.title
        event.startDate = range.start
        event.endDate = range.end
        event.notes = notes
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func remove(eventID: String) {
        guard let event = eventStore.event(withIdentifier: eventID) else { return }
        try? eventStore.remove(event, span: .thisEvent, commit: true)
    }

    private func targetCalendar() -> EKCalendar? {
        if let calendar { return calendar }
        if let id = UserDefaults.standard.string(forKey: "itimer.calendarID"),
           let existing = eventStore.calendar(withIdentifier: id) {
            calendar = existing
            return existing
        }
        guard let source = eventStore.defaultCalendarForNewEvents?.source
                ?? eventStore.sources.first(where: { $0.sourceType == .local }) else { return nil }
        let fresh = EKCalendar(for: .event, eventStore: eventStore)
        fresh.title = "iTimer"
        fresh.source = source
        fresh.cgColor = NSColor.systemIndigo.cgColor
        do {
            try eventStore.saveCalendar(fresh, commit: true)
            UserDefaults.standard.set(fresh.calendarIdentifier, forKey: "itimer.calendarID")
            calendar = fresh
            return fresh
        } catch {
            return nil
        }
    }
}

@MainActor
final class CalendarManager {
    static let shared = CalendarManager()

    let syncer = EventKitSync()
    private var refresher: DispatchSourceTimer?

    func attach(to store: TaskStore) {
        guard store.syncer == nil else { return }
        store.syncer = syncer
        startRefresh(store: store)
    }

    /// Toggle-on path: ask for permission, enable only if granted.
    func requestEnable() async {
        let granted = await syncer.requestAccess()
        TaskStore.shared.setCalendarSyncEnabled(granted)
    }

    private func startRefresh(store: TaskStore) {
        guard refresher == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak store] in
            Task { @MainActor in
                guard let store, store.calendarSyncEnabled else { return }
                for task in store.runningTasks {
                    store.resync(id: task.id)
                }
            }
        }
        timer.resume()
        refresher = timer
    }
}
