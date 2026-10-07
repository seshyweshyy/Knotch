//
//  CalendarServiceProvider.swift
//  Calendr
//
//  Created by Paker on 31/12/20.
//  Original source: Original source: https://github.com/pakerwreah/Calendr
//  Modified by Alexander on 08/06/25
//

import Foundation
@preconcurrency import EventKit

@MainActor
protocol CalendarServiceProviding {
    func requestAccess(to type: EKEntityType) async throws -> Bool
    func calendars() async -> [CalendarModel]
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel]
}

@MainActor
final class CalendarService: CalendarServiceProviding {
    // A single EKEventStore per process — Apple's EventKit engineers have
    // flagged multiple live instances as a source of flaky authorization
    // callbacks on macOS 14+ (requestFullAccessTo... silently returning
    // false with no prompt). CalendarManager and OnboardingView both go
    // through this instance rather than creating their own.
    static let shared = CalendarService()

    private let store = EKEventStore()
    private var storeRevision: UInt64 = 0
    private var eventStoreChangedObserver: NSObjectProtocol?

    private init() {
        // A result fetched while CalendarAgent is applying a database change
        // can be incomplete. Track the store's notification generation so a
        // query that overlaps a change can be discarded instead of merged
        // with a later result (which would resurrect genuinely deleted items).
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.storeRevision &+= 1
            }
        }
    }

    isolated deinit {
        if let eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(eventStoreChangedObserver)
        }
    }
    
    func requestAccess(to type: EKEntityType) async throws -> Bool {
        if #available(macOS 14.0, *) {
            // The very first EventKit full-access call on a freshly-created
            // EKEventStore can race the XPC connection to CalendarAgent and
            // come back `false` before the user was ever actually asked —
            // authorizationStatus stays .notDetermined in that case, unlike
            // a real "Don't Allow" (which moves it to .denied). That specific
            // signature is the only case safe to retry, since we're not
            // re-prompting after a genuine decision.
            for attempt in 0..<3 {
                let granted = try await requestFullAccess(to: type)
                if granted { return true }

                let statusAfter = EKEventStore.authorizationStatus(for: type)
                guard statusAfter == .notDetermined else { return false }

                NSLog("[CalendarService] requestAccess(\(type)) returned false but status is still notDetermined (attempt \(attempt + 1)/3) — retrying")
                try? await Task.sleep(for: .milliseconds(400))
            }
            return false
        } else {
            return try await store.requestAccess(to: type)
        }
    }

    @available(macOS 14.0, *)
    private func requestFullAccess(to type: EKEntityType) async throws -> Bool {
        switch type {
        case .event:
            return try await store.requestFullAccessToEvents()
        case .reminder:
            return try await store.requestFullAccessToReminders()
        @unknown default:
            return false
        }
    }
    
    private func hasAccess(to entityType: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: entityType)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }
    
    func calendars() async -> [CalendarModel] {
        var calendars: [EKCalendar] = []
        
        for type in [EKEntityType.event, .reminder] where hasAccess(to: type) {
            calendars.append(contentsOf: store.calendars(for: type))
        }
        
        return calendars.map { CalendarModel(from: $0) }
    }
    
    func events(from start: Date, to end: Date, calendars ids: [String]) async -> [EventModel] {
        let selectedIDs = Set(ids)
        var reminders: [EventModel] = []

        // Fetch reminders
        if hasAccess(to: .reminder) {
            let reminderCalendars = store.calendars(for: .reminder).filter {
                selectedIDs.isEmpty || selectedIDs.contains($0.calendarIdentifier)
            }
            reminders = await fetchReminders(from: start, to: end, calendars: reminderCalendars)
        }

        // Query events last. Reminder fetching is asynchronous and may take
        // up to its timeout; doing the validated event read afterwards keeps
        // the event snapshot current at the point this method returns.
        let events = await stableEventSnapshot(
            from: start,
            to: end,
            selectedCalendarIDs: selectedIDs
        )

        return (events + reminders).sorted { $0.start < $1.start }
    }

    /// Returns one authoritative local EventKit snapshot. EventKit does not
    /// expose a "sync complete" flag, but it does tell us when the backing
    /// database changed. Holding the result for a short validation window
    /// lets us discard only queries that overlapped such a change.
    private func stableEventSnapshot(
        from start: Date,
        to end: Date,
        selectedCalendarIDs: Set<String>
    ) async -> [EventModel] {
        guard hasAccess(to: .event) else { return [] }

        let validationWindow = Duration.milliseconds(350)
        var lastSnapshot: [EventModel] = []
        var attempt = 0

        while true {
            attempt += 1
            let revisionBeforeQuery = storeRevision
            lastSnapshot = eventSnapshot(
                from: start,
                to: end,
                selectedCalendarIDs: selectedCalendarIDs
            )

            do {
                try await Task.sleep(for: validationWindow)
                try Task.checkCancellation()
            } catch is CancellationError {
                return lastSnapshot
            } catch {
                return lastSnapshot
            }

            guard storeRevision != revisionBeforeQuery else {
                return lastSnapshot
            }

            NSLog("[CalendarService] Event store changed during range query; discarding snapshot and retrying (attempt \(attempt))")
        }
    }

    private func eventSnapshot(
        from start: Date,
        to end: Date,
        selectedCalendarIDs: Set<String>
    ) -> [EventModel] {
        // Querying all event calendars avoids handing the predicate EKCalendar
        // objects that may have gone stale during a source refresh. Apply the
        // user's identifier selection to the returned events instead.
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter {
                selectedCalendarIDs.isEmpty ||
                selectedCalendarIDs.contains($0.calendar.calendarIdentifier)
            }
            .compactMap(EventModel.init(from:))
            .sorted { $0.start < $1.start }
    }
    
    private func fetchReminders(from start: Date, to end: Date, calendars: [EKCalendar]) async -> [EventModel] {
        guard !calendars.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: calendars)
            var resumed = false

            // Timeout: if EKEventStore never calls back, unblock after 3 seconds
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: [])
            }

            store.fetchReminders(matching: predicate) { reminders in
                Task { @MainActor in
                    guard !resumed else { return }
                    resumed = true
                    timeoutTask.cancel()

                    guard let reminders else {
                        continuation.resume(returning: [])
                        return
                    }
                    let filtered = reminders.compactMap { reminder -> EventModel? in
                        guard let dueDate = reminder.dueDateComponents?.date,
                              dueDate >= start,
                              dueDate <= end else {
                            return nil
                        }
                        return EventModel(from: reminder)
                    }
                    continuation.resume(returning: filtered)
                }
            }
        }
    }
    
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            print("Failed to update reminder completion: \(error)")
        }
    }
}

// MARK: - Model Extensions

extension CalendarModel {
    init(from calendar: EKCalendar) {
        self.init(
            id: calendar.calendarIdentifier,
            account: calendar.accountTitle,
            title: calendar.title,
            color: calendar.color,
            isSubscribed: calendar.isSubscribed || calendar.isDelegate,
            isReminder: calendar.allowedEntityTypes.contains(.reminder)
        )
    }
}

extension EventModel {
    init?(from event: EKEvent) {
        guard let calendar = event.calendar else { return nil }
        
        self.init(
            id: event.calendarItemIdentifier,
            start: event.startDate,
            end: event.endDate,
            title: event.title ?? "",
            location: event.location,
            notes: event.notes,
            url: event.url,
            isAllDay: event.shouldBeAllDay,
            type: .init(from: event),
            calendar: .init(from: calendar),
            participants: .init(from: event),
            timeZone: calendar.isSubscribed || calendar.isDelegate ? nil : event.timeZone,
            hasRecurrenceRules: event.hasRecurrenceRules || event.isDetached,
            priority: nil
        )
    }
    
    init?(from reminder: EKReminder) {
        guard let calendar = reminder.calendar,
              let dueDateComponents = reminder.dueDateComponents,
              let date = Calendar.current.date(from: dueDateComponents)
        else { return nil }
        
        self.init(
            id: reminder.calendarItemIdentifier,
            start: date,
            end: Calendar.current.endOfDay(for: date),
            title: reminder.title ?? "",
            location: reminder.location,
            notes: reminder.notes,
            url: reminder.url,
            isAllDay: dueDateComponents.hour == nil,
            type: .reminder(completed: reminder.isCompleted),
            calendar: .init(from: calendar),
            participants: [],
            timeZone: calendar.isSubscribed || calendar.isDelegate ? nil : reminder.timeZone,
            hasRecurrenceRules: reminder.hasRecurrenceRules,
            priority: .init(from: reminder.priority)
        )
    }
}

extension EventType {
    init(from event: EKEvent) {
        self = event.birthdayContactIdentifier != nil ? .birthday : .event(.init(from: event.currentUser?.participantStatus))
    }
}

extension AttendanceStatus {
    init(from status: EKParticipantStatus?) {
        switch status {
        case .accepted:
            self = .accepted
        case .tentative:
            self = .maybe
        case .declined:
            self = .declined
        case .pending:
            self = .pending
        default:
            self = .unknown
        }
    }
}

extension Array where Element == Participant {
    init(from event: EKEvent) {
        var participants = event.attendees ?? []
        if let organizer = event.organizer, !participants.contains(where: { $0.url == organizer.url }) {
            participants.append(organizer)
        }
        self.init(
            participants.map { .init(from: $0, isOrganizer: $0.url == event.organizer?.url) }
        )
    }
}

extension Participant {
    init(from participant: EKParticipant, isOrganizer: Bool) {
        self.init(
            name: participant.name ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
            status: .init(from: participant.participantStatus),
            isOrganizer: isOrganizer,
            isCurrentUser: participant.isCurrentUser
        )
    }
}

extension Priority {
    init?(from p: Int) {
        switch p {
        case 1...4:
            self = .high
        case 5:
            self = .medium
        case 6...9:
            self = .low
        default:
            return nil
        }
    }
}

// MARK: - Helper Extensions

private extension EKCalendar {
    var accountTitle: String {
        switch source.sourceType {
        case .local, .subscribed, .birthdays:
            return "Other"
        default:
            return source.title
        }
    }
    
    var isDelegate: Bool {
        if #available(macOS 13.0, *) {
            return source.isDelegate
        } else {
            return false
        }
    }
}

private extension EKEvent {
    var currentUser: EKParticipant? {
        attendees?.first(where: \.isCurrentUser)
    }
    
    var shouldBeAllDay: Bool {
        guard !isAllDay else { return true }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: startDate)
        let endOfDay = calendar.dateInterval(of: .day, for: endDate)?.end
        return startDate == startOfDay && endDate == endOfDay
    }
}

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        dateInterval(of: .day, for: date)?.end ?? date
    }
}
