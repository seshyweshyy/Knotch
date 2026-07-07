//
//  TimerManager.swift
//  Knotch
//


import Foundation
import Combine
import Defaults
import UserNotifications

extension Defaults.Keys {
    static let persistedTimers = Key<[KnotchTimer]>("persistedTimers", default: [])
}

final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    @Published var timers: [KnotchTimer] = []
    @Published var isCreatingTimer: Bool = false   // drives the full-notch slider takeover (image 1)
    @Published var showTimerList: Bool = false     // drives the open-notch popup (image 3)

    private var tickCancellable: AnyCancellable?

    private init() {
        // Restore persisted timers; silently drop any that already finished while we were closed/quit.
        timers = Defaults[.persistedTimers].filter { !$0.isExpired }

        tickCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var soonestActiveTimer: KnotchTimer? {
        timers.filter { !$0.isPaused }.min { $0.endDate < $1.endDate } ?? timers.first
    }

    func start(name: String, duration: TimeInterval) {
        timers.append(KnotchTimer(name: name.isEmpty ? "Timer" : name, duration: duration))
        persist()
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
    }

    func resume(id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let remaining = timers[i].remainingAtPause ?? timers[i].duration
        timers[i].endDate = Date().addingTimeInterval(remaining)
        timers[i].isPaused = false
        timers[i].remainingAtPause = nil
        persist()
    }

    func cancel(id: UUID) {
        timers.removeAll { $0.id == id }
        persist()
        if timers.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.showTimerList = false
            }
        }
    }

    private func tick() {
        let expired = timers.filter { $0.isExpired }
        if !expired.isEmpty {
            expired.forEach(fireCompletionNotification)
            timers.removeAll { $0.isExpired }
            persist()
            if timers.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.showTimerList = false
                }
            }
        }
        objectWillChange.send() // keep countdown text updating every second
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
