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
    @State private var isExpanded: Bool = false
    @Namespace private var artNamespace

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .allowsHitTesting(false)

            VStack {
                Spacer()
                LiquidGlassMusicWidget(isExpanded: $isExpanded, artNamespace: artNamespace)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity),
                            removal:   .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
                        )
                    )
                    .allowsHitTesting(true)
                Spacer().frame(height: 210)
            }
            .frame(width: geo.size.width)

            // Expanded album art overlay
            if isExpanded {
                VStack {
                    Spacer()
                    ExpandedAlbumArtView(isExpanded: $isExpanded, artNamespace: artNamespace)
                        .frame(width: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 40, x: 0, y: 20)
                        .allowsHitTesting(true)
                    Spacer().frame(height: 120)
                }
                .frame(width: geo.size.width)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isExpanded)
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
