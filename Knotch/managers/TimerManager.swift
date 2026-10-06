//
//  TimerManager.swift
//  Knotch
//


import AppKit
import Foundation
import Combine
import Defaults
import SwiftUI
import UserNotifications

extension Defaults.Keys {
    static let persistedTimers = Key<[KnotchTimer]>("persistedTimers", default: [])
}

@MainActor
final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    @Published var timers: [KnotchTimer] = []
    @Published var systemTimers: [KnotchTimer] = []  // read-only mirror from Clock app, never persisted
    @Published var isCreatingTimer: Bool = false   // drives the full-notch slider takeover (image 1)
    @Published var showTimerList: Bool = false     // drives the open-notch popup (image 3)
    @Published private(set) var isPausedIdle: Bool = false   // true once every timer has sat paused for pauseDismissDelay
    // Knotch timers that just ran out, oldest first — kept (in memory only,
    // never persisted) until dismissed or restarted, so the expanded timer
    // card can show its "finished" alert. Mirrored Clock timers never land
    // here: their finish can't be told apart from a cancel.
    @Published private(set) var finishedTimers: [KnotchTimer] = []

    private var tickTimer: Timer?
    private var systemTimerProvider: SystemTimerProvider?
    private var pauseDismissTask: Task<Void, Never>?
    private static let pauseDismissDelay: TimeInterval = 3

    private init() {
        // Restore persisted timers; silently drop any that already finished while we were closed/quit.
        timers = Defaults[.persistedTimers].filter { !$0.isExpired }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        systemTimerProvider = SystemTimerProvider { [weak self] mirrored in
            Task { @MainActor in
                withAnimation {
                    self?.systemTimers = mirrored
                }
                self?.updatePausedIdleState()
            }
        }

        updatePausedIdleState()
    }

    var allTimers: [KnotchTimer] { timers + systemTimers }

    // Whether the timer's live activity is up (a timer exists and they aren't
    // all sitting paused past the idle delay).
    var hasLiveActivity: Bool { !allTimers.isEmpty && !isPausedIdle }

    var soonestActiveTimer: KnotchTimer? {
        allTimers.filter { !$0.isPaused }.min { $0.endDate < $1.endDate } ?? allTimers.first
    }

    // System timers are read-only mirrors — this just brings Clock.app forward
    // so the user can actually pause/cancel/rename the real thing.
    func revealInSystemClock() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") else { return }
        NSWorkspace.shared.open(url)
    }

    func start(name: String, duration: TimeInterval) {
        withAnimation {
            timers.append(KnotchTimer(name: name.isEmpty ? "Timer" : name, duration: duration))
        }
        persist()
        updatePausedIdleState()
    }

    func rename(id: UUID, name: String) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        timers[i].name = trimmed.isEmpty ? "Timer" : trimmed
        persist()
    }

    func pause(id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[i].remainingAtPause = timers[i].remaining()
        timers[i].isPaused = true
        persist()
        updatePausedIdleState()
    }

    func resume(id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let remaining = timers[i].remainingAtPause ?? timers[i].duration
        timers[i].endDate = Date().addingTimeInterval(remaining)
        timers[i].isPaused = false
        timers[i].remainingAtPause = nil
        persist()
        updatePausedIdleState()
    }

    func cancel(id: UUID) {
        withAnimation {
            timers.removeAll { $0.id == id }
        }
        persist()
        updatePausedIdleState()
        if allTimers.isEmpty {
            showTimerList = false
        }
    }

    // Clears a finished timer's alert without running it again.
    func dismissFinished(id: UUID) {
        withAnimation {
            finishedTimers.removeAll { $0.id == id }
        }
    }

    // Starts a fresh timer with a finished one's name and duration, and
    // clears its alert.
    func restartFinished(id: UUID) {
        guard let finished = finishedTimers.first(where: { $0.id == id }) else { return }
        dismissFinished(id: id)
        start(name: finished.name, duration: finished.duration)
    }

    private func tick() {
        let expired = timers.filter { $0.isExpired }
        if !expired.isEmpty {
            expired.forEach(fireCompletionNotification)
            withAnimation {
                timers.removeAll { $0.isExpired }
                finishedTimers.append(contentsOf: expired)
            }
            persist()
            updatePausedIdleState()
            if allTimers.isEmpty {
                showTimerList = false
            }
        }
        // Only broadcast while a countdown is actually advancing — this is
        // @ObservedObject'd by ContentView (the whole notch tree), so sending
        // unconditionally forced a full re-render every second even with no
        // timers running at all.
        if allTimers.contains(where: { !$0.isPaused }) {
            objectWillChange.send()
        }
    }

    /// A countdown needs a one-second UI heartbeat, but an idle or entirely
    /// paused timer list does not. Keeping no run-loop timer in those states
    /// avoids waking Knotch once a second for the lifetime of the app.
    private func updateTickingState() {
        let needsTicks = allTimers.contains { !$0.isPaused }
        guard needsTicks else {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // Mirrors MusicManager's play/pause idle debounce: once every timer is
    // paused (nothing counting down), wait pauseDismissDelay before hiding
    // the live activity, so a quick pause/resume doesn't cause a flicker.
    // Any timer running again cancels the countdown immediately.
    private func updatePausedIdleState() {
        updateTickingState()
        let anyRunning = allTimers.contains { !$0.isPaused }
        if anyRunning || allTimers.isEmpty {
            pauseDismissTask?.cancel()
            pauseDismissTask = nil
            if isPausedIdle {
                withAnimation { isPausedIdle = false }
            }
        } else if pauseDismissTask == nil {
            pauseDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.pauseDismissDelay))
                guard !Task.isCancelled, let self else { return }
                withAnimation { self.isPausedIdle = true }
                self.pauseDismissTask = nil
            }
        }
    }

    private func persist() {
        Defaults[.persistedTimers] = timers
    }

    private func fireCompletionNotification(for timer: KnotchTimer) {
        let content = UNMutableNotificationContent()
        content.title = timer.name
        content.body = "Time's up"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: nil)
        )
    }
}
