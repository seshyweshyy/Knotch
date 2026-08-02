//
//  UpdateFlowState.swift
//  Knotch
//

import Foundation
import Sparkle

/// Shared state between `KnotchUpdateUserDriver` (which receives Sparkle's
/// callbacks) and the SwiftUI views that render the update window.
@MainActor
final class UpdateFlowState: ObservableObject {
    enum Phase {
        case idle
        case checking(cancel: () -> Void)
        case found(item: SUAppcastItem, updateState: SPUUserUpdateState, reply: (SPUUserUpdateChoice) -> Void)
        case notFound(acknowledge: () -> Void)
        case downloading(cancel: () -> Void)
        case extracting(progress: Double)
        case readyToInstall(reply: (SPUUserUpdateChoice) -> Void)
        case installing
        case error(error: NSError, acknowledge: () -> Void)
    }

    @Published var phase: Phase = .idle
    @Published var downloadExpectedLength: UInt64 = 0
    @Published var downloadReceivedLength: UInt64 = 0

    /// Set when `.found` fires and kept around through the downloading/
    /// extracting/ready-to-install phases that follow, so the found-update
    /// screen (title, version badge, release notes) can stay on screen the
    /// whole time instead of being swapped for a separate progress window.
    @Published var foundItem: SUAppcastItem?

    /// Invoked when the window is closed without the user picking a button
    /// (red close button, Esc). Always treated as "remind me later" / plain
    /// acknowledgement — there's no skip path yet.
    func dismissCurrentPhase() {
        switch phase {
        case .found(_, _, let reply), .readyToInstall(let reply):
            reply(.dismiss)
        case .notFound(let acknowledge), .error(_, let acknowledge):
            acknowledge()
        case .checking(let cancel), .downloading(let cancel):
            cancel()
        case .idle, .extracting, .installing:
            break
        }
    }
}
