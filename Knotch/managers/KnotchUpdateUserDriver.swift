//
//  KnotchUpdateUserDriver.swift
//  Knotch
//

import AppKit
import Sparkle
import SwiftUI

/// Custom Sparkle UI driver. Replaces `SPUStandardUserDriver` so the update
/// flow can be restyled to match the rest of Knotch instead of using
/// Sparkle's stock alert windows (see project_custom_sparkle_ui memory).
///
/// Visuals are a placeholder for now — this pass only wires the flow up so
/// nothing that reads `SPUUpdater` off the old `SPUStandardUpdaterController`
/// breaks. Styling comes in a follow-up.
@MainActor
final class KnotchUpdateUserDriver: NSObject, SPUUserDriver {
    private let state = UpdateFlowState()
    private var windowController: UpdateWindowController?

    private func presentWindow() {
        if windowController == nil {
            windowController = UpdateWindowController(state: state, onWindowClosedWithoutChoice: { [weak self] in
                self?.state.dismissCurrentPhase()
            })
        }
        windowController?.show()
    }

    private func closeWindow() {
        windowController?.close()
        windowController = nil
    }

    // MARK: - Permission

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // No dedicated UI yet — default to automatic checks enabled, no system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        state.foundItem = nil
        state.phase = .checking(cancel: cancellation)
        presentWindow()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state userUpdateState: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        state.foundItem = appcastItem
        state.phase = .found(item: appcastItem, updateState: userUpdateState, reply: reply)
        presentWindow()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes are already inline in the appcast description; nothing to do.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Non-fatal — the found-update screen already has the inline notes.
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state.phase = .notFound(acknowledge: acknowledgement)
        presentWindow()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state.phase = .error(error: error as NSError, acknowledge: acknowledgement)
        presentWindow()
    }

    // MARK: - Downloading

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        state.phase = .downloading(cancel: cancellation)
        state.downloadExpectedLength = 0
        state.downloadReceivedLength = 0
        presentWindow()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        state.downloadExpectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        state.downloadReceivedLength += length
    }

    // MARK: - Extracting

    func showDownloadDidStartExtractingUpdate() {
        state.phase = .extracting(progress: 0)
        presentWindow()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        state.phase = .extracting(progress: progress)
    }

    // MARK: - Installing

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        state.phase = .readyToInstall(reply: reply)
        presentWindow()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        state.phase = .installing
        presentWindow()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        state.phase = .idle
        state.foundItem = nil
        closeWindow()
    }
}
