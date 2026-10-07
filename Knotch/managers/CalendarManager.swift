//
//  CalendarManager.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var eventStoreRevision: UInt64 = 0
    @Published private(set) var eventSnapshotRevision: UInt64 = 0
    @Published private(set) var loadedEventsDate: Date?
    @Published private(set) var compactUpcomingEvents: [EventModel] = []
    @Published private(set) var compactUpcomingStartDate: Date?
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService.shared
    private let eventFetchLimiter = EventFetchLimiter()

    private var eventStoreChangedObserver: NSObjectProtocol?
    private var pendingStoreChangeTask: Task<Void, Never>?
    private var pendingUpdateTask: Task<Void, Never>?
    private var pendingUpdateDate: Date?
    private var pendingUpdateGeneration: UInt64 = 0
    private var eventsSnapshotFetchedAt: Date?
    private var compactUpcomingFetchTask: Task<Void, Never>?
    private var compactUpcomingRequestStart: Date?
    private var compactUpcomingGeneration: UInt64 = 0
    private var compactUpcomingFetchedAt: Date?
    private var calendarListsLoaded = false
    private let snapshotFreshnessInterval: TimeInterval = 20

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
            let compactCalendarEnabled = Defaults[.compactShowCalendarView]
            if compactCalendarEnabled || Defaults[.lockScreenCalendarMiniWidget] {
                scheduleUpdate(for: .now)
            }
            if compactCalendarEnabled, !Defaults[.compactCalendarShowMonthView] {
                prefetchCompactUpcomingEvents()
            }
        }
    }

    isolated deinit {
        pendingUpdateTask?.cancel()
        pendingStoreChangeTask?.cancel()
        compactUpcomingFetchTask?.cancel()
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEventStoreChange()
            }
        }
    }

    private func handleEventStoreChange() {
        // The next request must not be suppressed by the short reopen cache.
        // Existing data can remain visible while the authoritative refresh
        // waits for CalendarAgent's notification burst to settle.
        invalidateSnapshotFreshness()
        pendingStoreChangeTask?.cancel()
        pendingStoreChangeTask = Task { [weak self] in
            // CalendarAgent commonly emits a burst while applying one sync.
            // Refetch once the burst goes quiet, and replace the UI snapshot.
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
            } catch {
                return
            }

            guard let self else { return }
            await self.reloadCalendarAndReminderLists()
            guard !Task.isCancelled else { return }
            self.eventStoreRevision &+= 1
            await self.updateEvents()
            self.prefetchCompactUpcomingEvents(force: true)
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
        calendarListsLoaded = true
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            NSLog("[CalendarManager] Current calendar authorization status: \(status.rawValue)")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await calendarService.requestAccess(to: .event)
                NSLog("[CalendarManager] Calendar requestAccess granted=\(granted)")
            } catch {
                NSLog("[CalendarManager] Calendar requestAccess threw: \(error)")
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                let snapshot = await calendarService.events(
                    from: currentWeekStartDate,
                    to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                    calendars: selectedCalendars.map { $0.id })
                applyEventsSnapshot(snapshot, for: currentWeekStartDate)
                prefetchCompactUpcomingEvents(relativeTo: currentWeekStartDate)
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            let snapshot = await calendarService.events(
                from: currentWeekStartDate,
                to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                calendars: selectedCalendars.map { $0.id })
            applyEventsSnapshot(snapshot, for: currentWeekStartDate)
            prefetchCompactUpcomingEvents(relativeTo: currentWeekStartDate)
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    /// Unlike checkCalendarAuthorization()'s passive onAppear check (which
    /// only calls requestAccess while status is .notDetermined), this always
    /// attempts the request — used by the Settings "Grant Access" button so
    /// it's never a dead click, even if status is .denied. EventKit simply
    /// won't show a dialog once the OS has truly decided, so this is a
    /// harmless no-op in that case rather than a spam risk.
    func requestCalendarAccess() async {
        do {
            let granted = try await calendarService.requestAccess(to: .event)
            NSLog("[CalendarManager] Manual Calendar requestAccess granted=\(granted)")
        } catch {
            NSLog("[CalendarManager] Manual Calendar requestAccess threw: \(error)")
        }
        await checkCalendarAuthorization()
    }

    func requestReminderAccess() async {
        do {
            let granted = try await calendarService.requestAccess(to: .reminder)
            NSLog("[CalendarManager] Manual Reminders requestAccess granted=\(granted)")
        } catch {
            NSLog("[CalendarManager] Manual Reminders requestAccess threw: \(error)")
        }
        await checkReminderAuthorization()
    }

    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            NSLog("[CalendarManager] Current reminder authorization status: \(status.rawValue)")
            self.reminderAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await calendarService.requestAccess(to: .reminder)
                NSLog("[CalendarManager] Reminders requestAccess granted=\(granted)")
            } catch {
                NSLog("[CalendarManager] Reminders requestAccess threw: \(error)")
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
        

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        invalidateSnapshotFreshness()
        await updateEvents()
        prefetchCompactUpcomingEvents(relativeTo: currentWeekStartDate, force: true)
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func scheduleUpdate(for date: Date) {
        let start = Calendar.current.startOfDay(for: date)
        currentWeekStartDate = start

        // CalendarManager's launch task will schedule this again once the
        // restored calendar selection is available.
        guard calendarListsLoaded else { return }

        if loadedEventsDate == start, isFresh(eventsSnapshotFetchedAt) {
            return
        }

        // The notch-open prefetch and CompactCalendarView's .task can arrive
        // a frame apart. Keep the first request alive instead of cancelling
        // it and starting the exact same EventKit query again.
        if pendingUpdateDate == start, pendingUpdateTask != nil {
            return
        }

        pendingUpdateTask?.cancel()
        pendingUpdateGeneration &+= 1
        let generation = pendingUpdateGeneration
        pendingUpdateDate = start
        pendingUpdateTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.updateEvents()
            guard generation == self.pendingUpdateGeneration else { return }
            self.pendingUpdateDate = nil
            self.pendingUpdateTask = nil
        }
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    // Separate from `events`/`updateEvents()`, which only cover the single
    // selected day — the compact calendar's event-dot indicators need every
    // event across the displayed month instead.
    func fetchMonthEvents(for date: Date) async -> [EventModel] {
        guard let interval = Calendar.current.dateInterval(of: .month, for: date) else { return [] }
        let calendarIDs = Array(selectedCalendarIDs)
        let service = calendarService
        return await eventFetchLimiter.run {
            await service.events(from: interval.start, to: interval.end, calendars: calendarIDs)
        }
    }

    // Used by the compact calendar's agenda column to fall back to
    // tomorrow's events when today has nothing left to show on the right —
    // separate from `events`/currentWeekStartDate, which stay pinned to
    // whatever day is currently selected.
    func fetchDayEvents(for date: Date, days: Int = 1) async -> [EventModel] {
        let start = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let calendarIDs = Array(selectedCalendarIDs)
        let service = calendarService
        return await eventFetchLimiter.run {
            await service.events(from: start, to: end, calendars: calendarIDs)
        }
    }

    /// Keeps the compact calendar's tomorrow + day-after snapshot alive even
    /// while its SwiftUI page is destroyed. Calls for the same range coalesce,
    /// so app launch, notch open, and page switching do not duplicate work.
    func prefetchCompactUpcomingEvents(relativeTo date: Date = .now, force: Bool = false) {
        // On launch CalendarManager first restores the user's selected IDs.
        // Deferring until that finishes prevents an early empty-ID request
        // from briefly caching events from every calendar.
        guard calendarListsLoaded else { return }
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return }
        let start = calendar.startOfDay(for: tomorrow)

        if !force,
           compactUpcomingStartDate == start,
           isFresh(compactUpcomingFetchedAt)
        {
            return
        }

        if !force, compactUpcomingRequestStart == start, compactUpcomingFetchTask != nil {
            return
        }

        compactUpcomingFetchTask?.cancel()
        compactUpcomingGeneration &+= 1
        let generation = compactUpcomingGeneration
        compactUpcomingRequestStart = start

        compactUpcomingFetchTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let snapshot = await self.fetchDayEvents(for: start, days: 2)
            guard !Task.isCancelled, generation == self.compactUpcomingGeneration else { return }

            self.compactUpcomingEvents = snapshot
            self.compactUpcomingStartDate = start
            self.compactUpcomingFetchedAt = .now
            self.compactUpcomingRequestStart = nil
            self.compactUpcomingFetchTask = nil
        }
    }

    private func updateEvents() async {
        let calendarIDs = selectedCalendars.map { $0.id }
        let startDate = currentWeekStartDate
           guard let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) else { return }
           let service = calendarService
           let eventsResult = await eventFetchLimiter.run {
               await service.events(from: startDate, to: endDate, calendars: calendarIDs)
           }
           guard !Task.isCancelled, startDate == currentWeekStartDate else { return }
           applyEventsSnapshot(eventsResult, for: startDate)
    }

    private func applyEventsSnapshot(_ snapshot: [EventModel], for date: Date) {
        events = snapshot
        loadedEventsDate = date
        eventsSnapshotFetchedAt = .now
        // Unlike observing `events` itself, this advances even when two
        // authoritative snapshots contain the same values (including []).
        eventSnapshotRevision &+= 1
    }

    private func isFresh(_ fetchedAt: Date?) -> Bool {
        guard let fetchedAt else { return false }
        let age = Date.now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < snapshotFreshnessInterval
    }

    private func invalidateSnapshotFreshness() {
        eventsSnapshotFetchedAt = nil
        compactUpcomingFetchedAt = nil
    }
    
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        // Refresh events after updating
        let startDate = currentWeekStartDate
           guard let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) else { return }
           let service = calendarService
           let eventsResult = await eventFetchLimiter.run {
               await service.events(from: startDate, to: endDate, calendars: self.selectedCalendars.map { $0.id })
           }
           guard !Task.isCancelled, startDate == currentWeekStartDate else { return }
           applyEventsSnapshot(eventsResult, for: startDate)
    }
}

// MARK: - Event Fetch Limiter

private actor EventFetchLimiter {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isRunning = false

    func run<T>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await waitTurn()
        defer { resumeNext() }
        return await operation()
    }

    private func waitTurn() async {
        if !isRunning {
            isRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeNext() {
        if waiters.isEmpty {
            isRunning = false
            return
        }
        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}
