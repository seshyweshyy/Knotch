//
//  LiquidGlassWidgetWindow.swift
//  boringNotch
//
//  A dedicated full-screen transparent NSPanel that hosts the liquid glass
//  music widget on the lock screen. Sits above everything, passes clicks
//  through to the desktop except on the widget itself.
//
//  Usage (from AppDelegate):
//    LiquidGlassWidgetWindowController.shared.show(on: screen)
//    LiquidGlassWidgetWindowController.shared.hide()
//

import AppKit
import SwiftUI
import Defaults

class LiquidGlassWidgetWindow: BoringNotchSkyLightWindow {
    // configure() is no longer needed — BoringNotchSkyLightWindow already
    // sets level, appearance, collectionBehavior, backgroundColor etc.
    // Just override the things that differ:
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isMovable = false
        sharingType = .none
    }
}

// MARK: - Root SwiftUI host

/// Full-screen transparent container. The widget is pinned to the bottom-centre.
/// Clicks outside the widget rect pass through to the desktop.
private struct LiquidGlassWidgetRoot: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        GeometryReader { geo in
            Color.clear
                // Make the entire background click-through
                .contentShape(Rectangle())
                .allowsHitTesting(false)

            VStack {
                Spacer()
                // Widget centred, sitting ~110 pt from the bottom (above profile icon)
                LiquidGlassMusicWidget()
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity),
                            removal:   .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
                        )
                    )
                    // allowsHitTesting true so controls are tappable
                    .allowsHitTesting(true)
                Spacer().frame(height: 200)
            }
            .frame(width: geo.size.width)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Controller

class LiquidGlassWidgetWindowController {
    static let shared = LiquidGlassWidgetWindowController()
    private var window: LiquidGlassWidgetWindow?

    private init() {}

    // MARK: Show

    // AFTER:
    func show(on screen: NSScreen) {
        if window == nil {
            let win = LiquidGlassWidgetWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.contentView = NSHostingView(rootView: LiquidGlassWidgetRoot())
            window = win
        }

        guard let win = window else { return }
        win.setFrame(screen.frame, display: false)
        win.enableSkyLight()           // ← inherited from BoringNotchSkyLightWindow
        win.orderFrontRegardless()
    }

    func hide() {
        guard let win = window else { return }
        win.disableSkyLight()          // ← inherited from BoringNotchSkyLightWindow
        win.orderOut(nil)
    }

    func updateScreen(_ screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
    }
}
