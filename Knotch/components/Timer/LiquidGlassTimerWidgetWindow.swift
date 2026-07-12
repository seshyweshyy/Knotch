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

import AppKit
import Combine
import Defaults
import SwiftUI

// MARK: - Root SwiftUI host

private struct LiquidGlassTimerWidgetRoot: View {
    @ObservedObject var timerManager = TimerManager.shared

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
                Spacer().frame(height: 375)
            }
            .frame(width: geo.size.width)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: timerManager.soonestActiveTimer != nil)
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
    }

    private func hide() {
        guard let win = window else { return }
        win.disableSkyLight()
        win.orderOut(nil)
    }
}
