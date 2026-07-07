//
//  KnotchTimer.swift
//  Knotch
//


import Foundation
import Defaults

struct KnotchTimer: Identifiable, Codable, Equatable, Defaults.Serializable {
    let id: UUID
    var name: String
    var duration: TimeInterval       // original length, seconds
    var endDate: Date                // when it will/would have fired
    var isPaused: Bool
    var remainingAtPause: TimeInterval?

    init(name: String, duration: TimeInterval) {
        self.id = UUID()
        self.name = name
        self.duration = duration
        self.endDate = Date().addingTimeInterval(duration)
        self.isPaused = false
        self.remainingAtPause = nil
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if isPaused, let remainingAtPause {
            return remainingAtPause
        }
        return max(0, endDate.timeIntervalSince(date))
    }

    var isExpired: Bool {
        !isPaused && Date() >= endDate
    }
}
