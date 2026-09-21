// Finding the next meeting the guard should act on.

import EventKit
import Foundation

/// Finding the next meeting the guard should act on.
enum Meetings {
    /// Callback form. EKEventStore is not thread safe, so a caller that owns
    /// the store on one thread must stay on it - this never blocks or hops.
    static func requestAccess(
        _ store: EKEventStore, completion: @escaping @Sendable (Bool) -> Void
    ) {
        store.requestFullAccessToEvents { granted, error in
            if let error { Log.write("calendar access error: \(error.localizedDescription)") }
            completion(granted)
        }
    }

    /// Blocking form, for the command line tool where there is no run loop to
    /// return to.
    static func requestAccess(_ store: EKEventStore, timeout: TimeInterval = 30) -> Bool {
        // The callback lands on another queue, so the answer travels in a box
        // rather than a captured var.
        final class Answer: @unchecked Sendable {
            var granted = false
        }
        let answer = Answer()
        let semaphore = DispatchSemaphore(value: 0)
        store.requestFullAccessToEvents { ok, error in
            answer.granted = ok
            if let error { Log.write("calendar access error: \(error.localizedDescription)") }
            semaphore.signal()
        }
        // Never let a hung permission prompt wedge the caller.
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            Log.write("calendar access timed out")
            return false
        }
        return answer.granted
    }

    /// A personal focus block has no other attendees; a real meeting does. That
    /// single signal separates "Focus" and "Home-office" from "Weekly sync/review"
    /// without any title matching.
    static func isRealMeeting(_ event: EKEvent, config: GuardConfig) -> Bool {
        if event.isAllDay { return false }
        if event.status == .canceled { return false }
        if config.ignoreFreeEvents && event.availability == .free { return false }
        if let id = event.eventIdentifier, config.skippedEventIDs.contains(id) { return false }
        guard let attendees = event.attendees, attendees.count >= config.minAttendees else {
            // minAttendees of 0 or 1 means "any timed event counts".
            return config.minAttendees <= 1
        }
        if let me = attendees.first(where: { $0.isCurrentUser }), me.participantStatus == .declined {
            return false
        }
        return true
    }

    /// The calendars the guard looks at. Returns nil for "all of them", which
    /// is what EventKit's predicate wants, and an empty array for "none" -
    /// a selection that resolves to nothing must match nothing, not everything.
    static func watchedCalendars(_ store: EKEventStore, config: GuardConfig) -> [EKCalendar]? {
        guard !config.watchAllCalendars else { return nil }
        return store.calendars(for: .event)
            .filter { config.watchedCalendarIDs.contains($0.calendarIdentifier) }
    }

    static func nextMeeting(_ store: EKEventStore, within minutes: Double, config: GuardConfig) -> EKEvent? {
        let calendars = watchedCalendars(store, config: config)
        if let calendars, calendars.isEmpty { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(minutes * 60), calendars: calendars)
        return store.events(matching: predicate)
            .filter { $0.startDate > now && isRealMeeting($0, config: config) }
            .min { $0.startDate < $1.startDate }
    }
}
