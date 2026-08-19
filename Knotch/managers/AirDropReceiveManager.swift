//
//  AirDropReceiveManager.swift
//  Knotch
//

import AppKit
import Defaults
import Foundation

/// Tracks incoming file transfers landing in ~/Downloads using the public
/// `Progress.addSubscriber(forFileURL:withPublishingHandler:)` API — the same
/// mechanism behind Finder's file-icon download badges. sharingd (and other
/// writers, e.g. Safari/Mail saves) publish an NSProgress for the destination
/// file; this subscribes to it and mirrors real byte progress into the notch.
/// No private API and no Full Disk Access required.
@MainActor
final class AirDropReceiveManager {
    static let shared = AirDropReceiveManager()

    private var subscriberToken: Any?
    private var fractionObservation: NSKeyValueObservation?
    private var finishedObservation: NSKeyValueObservation?
    private var activeProgress: Progress?
    private var trackingInteraction = false

    private let watchedDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    /// Triggers the system Downloads-folder consent prompt on its own, ahead
    /// of the user's first real AirDrop transfer — `finish()` reads the
    /// folder's contents to resolve which file just landed, and that first
    /// read is what the OS gates, not `Progress.addSubscriber` itself. Used
    /// by onboarding so the prompt appears under an explained context
    /// instead of silently mid-transfer.
    func requestDownloadsFolderAccess() {
        _ = try? FileManager.default.contentsOfDirectory(
            at: watchedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private init() {
        subscriberToken = Progress.addSubscriber(forFileURL: watchedDirectory) { [weak self] progress in
            Task { @MainActor in
                self?.attach(to: progress)
            }
            return { [weak self] in
                Task { @MainActor in
                    self?.detach(progress)
                }
            }
        }
    }

    private func attach(to progress: Progress) {
        guard Defaults[.showAirDropReceiveProgress] else { return }

        // Distinguishes a real AirDrop transfer from other publishers of the
        // same mechanism (Finder copies, Safari/Mail downloads): sharingd
        // never sets `kind` on the progress it publishes, while Finder and
        // Safari both explicitly tag theirs as `.file`. Verified empirically
        // against a live AirDrop, a Finder copy, and a Safari download —
        // AirDrop stayed nil throughout, the other two were `.file` from
        // the first callback onward.
        guard progress.kind == nil else { return }

        if activeProgress !== progress {
            tearDown()
        }

        activeProgress = progress
        SharingStateManager.shared.beginInteraction()
        trackingInteraction = true

        KnotchViewCoordinator.shared.toggleAirDropReceiveSneakPeek()

        // The staleness check is re-done *inside* each Task, not just before
        // queuing it — fractionCompleted and isFinished fire as separate KVO
        // notifications with no ordering guarantee between them, so a
        // fractionCompleted callback queued a moment before isFinished can
        // still execute after finish() has already torn things down. Only
        // re-checking activeProgress at execution time (once teardown has
        // definitely already nil'd it out) actually catches that.
        fractionObservation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self, self.activeProgress === p else { return }
                KnotchViewCoordinator.shared.updateAirDropReceiveProgress(CGFloat(p.fractionCompleted))
            }
        }

        finishedObservation = progress.observe(\.isFinished, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self, p.isFinished, self.activeProgress === p else { return }
                self.finish()
            }
        }
    }

    private func finish() {
        let fileName = Self.mostRecentlyAddedFile(in: watchedDirectory)?.path ?? ""
        KnotchViewCoordinator.shared.completeAirDropReceive(filePath: fileName)
        tearDown()
    }

    private func detach(_ progress: Progress) {
        guard activeProgress === progress else { return }
        // isFinished never fired: the transfer was cancelled, declined, or failed.
        if !progress.isFinished {
            KnotchViewCoordinator.shared.cancelAirDropReceive()
        }
        tearDown()
    }

    private func tearDown() {
        fractionObservation = nil
        finishedObservation = nil
        if trackingInteraction {
            SharingStateManager.shared.endInteraction()
            trackingInteraction = false
        }
        activeProgress = nil
    }

    /// Resolves the file that just landed by "date added to folder" (not
    /// modification date — AirDrop preserves the sender's original mtime, so
    /// a newly-received file can carry an old timestamp there).
    private static func mostRecentlyAddedFile(in directory: URL, within seconds: TimeInterval = 10) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.addedToDirectoryDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let cutoff = Date().addingTimeInterval(-seconds)
        return items
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate,
                      date >= cutoff else { return nil }
                return (url, date)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }
}
