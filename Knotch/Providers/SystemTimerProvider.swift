//
//  SystemTimerProvider.swift
//  Knotch
//

import CoreFoundation
import Foundation

// Mirrors running/paused timers from the macOS Clock app.
//
// Clock's `mobiletimerd` daemon persists timer state under the
// "com.apple.mobiletimerd" preferences domain, which isn't behind Full Disk
// Access or any TCC prompt (Preferences domains aren't a protected location,
// unlike Desktop/Documents/Mail/etc). A timer entry's fire time is stored as
// an absolute date while running and as a remaining-seconds interval while
// paused/idle, keyed by `MTTimerState` (1 = idle, 2 = paused, 3 = running).
//
// Reads go through CFPreferencesCopyAppValue rather than parsing the on-disk
// plist directly: cfprefsd caches preference writes in memory and flushes to
// disk lazily (can lag a couple seconds behind the real state change), so a
// raw file read/watch is reading stale data even right after a pause/cancel.
// CFPreferences reads hit that same in-memory cache cfprefsd updates the
// instant mobiletimerd writes, so it reflects state changes immediately.
final class SystemTimerProvider {
    private static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.mobiletimerd.plist")
    private static let domain = "com.apple.mobiletimerd" as CFString
    private static let timersKey = "MTTimers" as CFString

    // How often to poll as a backstop. The kqueue watcher below delivers
    // most changes instantly, but mobiletimerd replaces the plist atomically
    // (unlink + rename) rather than writing in place, and a replace landing
    // in the brief gap while we're re-registering the watcher on the new
    // inode can be missed entirely — the poll bounds worst-case staleness
    // regardless of whether that race (or any other missed kqueue event) hits.
    private static let pollInterval: TimeInterval = 0.5

    private let onUpdate: ([KnotchTimer]) -> Void
    private var fileDescriptor: CInt = -1
    private var watcher: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?

    init(onUpdate: @escaping ([KnotchTimer]) -> Void) {
        self.onUpdate = onUpdate
        reload()
        startWatching()
        startPolling()
    }

    deinit {
        watcher?.cancel()
        pollTimer?.cancel()
    }

    private func startWatching() {
        let newFD = open(Self.plistURL.path, O_EVTONLY)
        guard newFD >= 0 else { return }

        let newWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: newFD,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        newWatcher.setEventHandler { [weak self] in
            guard let self else { return }
            self.reload()
            // mobiletimerd writes atomically (replace, not in-place), which
            // invalidates the watched descriptor — reopen it on the new inode.
            if newWatcher.data.contains(.delete) || newWatcher.data.contains(.rename) {
                self.startWatching()
            }
        }
        newWatcher.setCancelHandler { [newFD] in
            close(newFD)
        }
        newWatcher.resume()

        // Swap in the new watcher before tearing down the old one so there's
        // no gap where a replace could land unobserved.
        let oldWatcher = watcher
        watcher = newWatcher
        fileDescriptor = newFD
        oldWatcher?.cancel()
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.reload() }
        timer.resume()
        pollTimer = timer
    }

    private func reload() {
        let mirrored = Self.parse()
        DispatchQueue.main.async { [onUpdate] in
            onUpdate(mirrored)
        }
    }

    private static func parse() -> [KnotchTimer] {
        // Force-reconcile our process's local CFPreferences cache with
        // cfprefsd's authoritative in-memory state before reading, so we
        // don't serve back a snapshot from before the last pause/cancel.
        CFPreferencesAppSynchronize(domain)

        guard
            let mtTimers = CFPreferencesCopyAppValue(timersKey, domain) as? [String: Any],
            let entries = mtTimers["MTTimers"] as? [[String: Any]]
        else {
            return []
        }

        let now = Date()
        return entries.compactMap { entry -> KnotchTimer? in
            guard
                let timer = entry["$MTTimer"] as? [String: Any],
                let idString = timer["MTTimerID"] as? String,
                let id = UUID(uuidString: idString),
                let state = timer["MTTimerState"] as? Int,
                state == 2 || state == 3,   // only currently paused/running timers; skip idle history
                let duration = timer["MTTimerDuration"] as? Double,
                let fireTime = timer["MTTimerFireTime"] as? [String: Any]
            else { return nil }

            let isPaused = state == 2
            let name = (timer["MTTimerTitle"] as? String) ?? "Timer"

            let endDate: Date
            let remainingAtPause: TimeInterval?
            if let dateBox = fireTime["$MTTimerDate"] as? [String: Any],
               let fireDate = dateBox["MTTimerTimeDate"] as? Date {
                endDate = fireDate
                remainingAtPause = nil
            } else if let intervalBox = fireTime["$MTTimerTimeInterval"] as? [String: Any],
                      let remaining = intervalBox["MTTimerTimeInterval"] as? Double {
                endDate = now.addingTimeInterval(remaining)
                remainingAtPause = isPaused ? remaining : nil
            } else {
                return nil
            }

            return KnotchTimer(
                systemID: id,
                name: name,
                duration: duration,
                endDate: endDate,
                isPaused: isPaused,
                remainingAtPause: remainingAtPause
            )
        }
    }
}
