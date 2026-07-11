//
//  KnotchTimer.swift
//  Knotch
//


import Foundation
import Defaults

enum TimerSource: String, Codable, Equatable {
    case knotch
    case systemClock   // mirrored read-only from the macOS Clock app
}

struct KnotchTimer: Identifiable, Codable, Equatable, Defaults.Serializable {
    let id: UUID
    var name: String
    var duration: TimeInterval       // original length, seconds
    var endDate: Date                // when it will/would have fired
    var isPaused: Bool
    var remainingAtPause: TimeInterval?
    var source: TimerSource

    init(name: String, duration: TimeInterval) {
        self.id = UUID()
        self.name = name
        self.duration = duration
        self.endDate = Date().addingTimeInterval(duration)
        self.isPaused = false
        self.remainingAtPause = nil
        self.source = .knotch
    }

    // Mirrors a running/paused timer read from the Clock app's mobiletimerd plist.
    // `systemID` is that timer's own MTTimerID so re-parsing the plist maps back to the same row.
    init(systemID: UUID, name: String, duration: TimeInterval, endDate: Date, isPaused: Bool, remainingAtPause: TimeInterval?) {
        self.id = systemID
        self.name = name
        self.duration = duration
        self.endDate = endDate
        self.isPaused = isPaused
        self.remainingAtPause = remainingAtPause
        self.source = .systemClock
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, duration, endDate, isPaused, remainingAtPause, source
    }

    // Custom decode so timers persisted before `source` existed still load (defaulting to .knotch).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        endDate = try c.decode(Date.self, forKey: .endDate)
        isPaused = try c.decode(Bool.self, forKey: .isPaused)
        remainingAtPause = try c.decodeIfPresent(TimeInterval.self, forKey: .remainingAtPause)
        source = try c.decodeIfPresent(TimerSource.self, forKey: .source) ?? .knotch
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
