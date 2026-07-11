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

final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    @Published var timers: [KnotchTimer] = []
    @Published var systemTimers: [KnotchTimer] = []  // read-only mirror from Clock app, never persisted
    @Published var isCreatingTimer: Bool = false   // drives the full-notch slider takeover (image 1)
    @Published var showTimerList: Bool = false     // drives the open-notch popup (image 3)
    @Published private(set) var isPausedIdle: Bool = false   // true once every timer has sat paused for pauseDismissDelay

    private var tickCancellable: AnyCancellable?
    private var systemTimerProvider: SystemTimerProvider?
    private var pauseDismissTask: Task<Void, Never>?
    private static let pauseDismissDelay: TimeInterval = 3

    private init() {
        // Restore persisted timers; silently drop any that already finished while we were closed/quit.
        timers = Defaults[.persistedTimers].filter { !$0.isExpired }

        tickCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        systemTimerProvider = SystemTimerProvider { [weak self] mirrored in
            withAnimation {
                self?.systemTimers = mirrored
            }
            self?.updatePausedIdleState()
        }

        updatePausedIdleState()
    }

    var allTimers: [KnotchTimer] { timers + systemTimers }

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
            DispatchQueue.main.async { [weak self] in
                self?.showTimerList = false
            }
        }
    }

    private func tick() {
        let expired = timers.filter { $0.isExpired }
        if !expired.isEmpty {
            expired.forEach(fireCompletionNotification)
            withAnimation {
                timers.removeAll { $0.isExpired }
            }
            persist()
            updatePausedIdleState()
            if allTimers.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.showTimerList = false
                }
            }
        }
        objectWillChange.send() // keep countdown text updating every second
    }

    // Mirrors MusicManager's play/pause idle debounce: once every timer is
    // paused (nothing counting down), wait pauseDismissDelay before hiding
    // the live activity, so a quick pause/resume doesn't cause a flicker.
    // Any timer running again cancels the countdown immediately.
    private func updatePausedIdleState() {
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
