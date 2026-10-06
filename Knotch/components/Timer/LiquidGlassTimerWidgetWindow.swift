//
//  LiquidGlassTimerWidgetWindow.swift
//  Knotch
//
//  A dedicated full-screen transparent NSPanel that hosts the liquid glass
//  timer widget on the lock screen. Entirely independent of the music widget
//  (LiquidGlassWidgetWindow.swift) — separate window, separate show/hide
//  lifecycle driven only by whether a timer is active, not by music state.
//  Positioned to sit just above where the music widget normally appears.
//
//  Usage (from AppDelegate):
//    LiquidGlassTimerWidgetWindowController.shared.screenDidLock(on: screen)
//    LiquidGlassTimerWidgetWindowController.shared.screenDidUnlock()
//

import AlbumArtBackgroundWindow
import AppKit
import Combine
import Defaults
import SwiftUI

// MARK: - Root SwiftUI host

/// Whether the music widget's expanded album art is up. Tracked here (from
/// the same hide/show notifications LiquidGlassWidgetWindow posts on
/// expand/collapse, which the lock-screen mini widget row also follows) rather
/// than in the root view: this window is only created once a timer is active,
/// which can be after the art was already expanded.
private final class LockScreenArtExpansionState: ObservableObject {
    static let shared = LockScreenArtExpansionState()

    @Published var isExpanded = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: .lockScreenProfileShouldHide)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isExpanded = true }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .lockScreenProfileShouldShow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isExpanded = false }
            .store(in: &cancellables)
    }
}

private struct LiquidGlassTimerWidgetRoot: View {
    @ObservedObject var timerManager = TimerManager.shared
    @ObservedObject var artExpansion = LockScreenArtExpansionState.shared

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                if timerManager.soonestActiveTimer != nil {
                    LiquidGlassTimerWidget()
                        .compositingGroup()
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }
                // Clears the music widget's own card (bottom-pinned ~210pt margin
                // plus its height) so this sits just above it. Not dynamically
                // computed from the music widget on purpose — the two are meant
                // to be independent; nudge this constant if spacing looks off.
                //
                // While the album art is expanded the music widget drops to a
                // 115pt bottom margin and the art + lyrics fill the space above
                // it, so the timer moves to sit under the music card instead:
                // 115 (its margin) - 12 (gap) - 70 (this widget's height).
                Spacer().frame(height: artExpansion.isExpanded ? 33 : 375)
            }
            .frame(width: geo.size.width)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: timerManager.soonestActiveTimer != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: artExpansion.isExpanded)
    }
}

private final class FirstMouseTimerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

final class LiquidGlassTimerWidgetWindowController {
    static let shared = LiquidGlassTimerWidgetWindowController()

    private var window: LiquidGlassWidgetWindow?
    private var isScreenLocked = false
    private var timerCancellable: AnyCancellable?

    private init() {
        // Start following the album art's expanded state from launch.
        _ = LockScreenArtExpansionState.shared
        timerCancellable = TimerManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires just before the value updates, so
                // defer the check to the next runloop tick.
                DispatchQueue.main.async { self?.refresh() }
            }
    }

    func screenDidLock(on screen: NSScreen) {
        isScreenLocked = true
        refresh(preferredScreen: screen)
    }

    func screenDidUnlock() {
        isScreenLocked = false
        refresh()
    }

    func updateScreen(_ screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
    }

    private func refresh(preferredScreen: NSScreen? = nil) {
        guard isScreenLocked, Defaults[.lockScreenTimerWidget], TimerManager.shared.soonestActiveTimer != nil else {
            hide()
            return
        }
        show(on: preferredScreen ?? window?.screen ?? NSScreen.main ?? NSScreen.screens[0])
    }

    private func show(on screen: NSScreen) {
        if window == nil {
            let win = LiquidGlassWidgetWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.contentView = FirstMouseTimerHostingView(rootView: LiquidGlassTimerWidgetRoot())
            window = win
        }

        guard let win = window else { return }
        win.setFrame(screen.frame, display: false)
        win.enableSkyLight()
        win.orderFrontRegardless()
        win.acquireActiveGlassAppearance()
    }

    private func hide() {
        guard let win = window else { return }
        win.releaseActiveGlassAppearance()
        win.disableSkyLight()
        win.orderOut(nil)
    }
}
