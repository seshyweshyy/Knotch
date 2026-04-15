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

            // Widget pinned to bottom-centre, moves down when expanded
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
                Spacer().frame(height: isExpanded ? 160 : 210)
            }
            .frame(width: geo.size.width)

            if isExpanded {
                // X button — absolute top-left of screen
                VStack {
                    HStack {
                        Button {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                                isExpanded = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.leading, 24)
                    .padding(.top, 24)
                    Spacer()
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(true)

                // Expanded art — centered horizontally, upper-mid vertically, detached from widget
                let artSize = min(geo.size.width, geo.size.height) * 0.42
                ExpandedAlbumArtView(isExpanded: $isExpanded, artNamespace: artNamespace)
                    .frame(width: artSize, height: artSize)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 40, x: 0, y: 20)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.46)
                    .allowsHitTesting(true)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isExpanded)
            .onChange(of: isExpanded) { _, expanded in
                if expanded {
                    AlbumArtBackgroundWindowController.shared.show()
                    NotificationCenter.default.post(name: .lockScreenProfileShouldHide, object: nil)
                } else {
                    AlbumArtBackgroundWindowController.shared.hide()
                    NotificationCenter.default.post(name: .lockScreenProfileShouldShow, object: nil)
                }
            }
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
