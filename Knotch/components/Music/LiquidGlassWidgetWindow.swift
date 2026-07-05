//
//  LiquidGlassWidgetWindow.swift
//  Knotch
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
import AlbumArtBackgroundWindow

/// Tracks the album art thumbnail's current on-screen frame so a window-level
/// event monitor can detect taps directly, bypassing AppKit's normal view
/// hit-testing/dispatch entirely.
final class AlbumArtHitRegion {
    static let shared = AlbumArtHitRegion()
    /// Frame in the SwiftUI top-left-origin coordinate space of the widget root.
    var frameInWindow: CGRect = .zero
}

extension Notification.Name {
    static let albumArtHitRegionTapped = Notification.Name("albumArtHitRegionTapped")
}

class LiquidGlassWidgetWindow: KnotchSkyLightWindow {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isMovable = false
        // sharingType is managed by KnotchSkyLightWindow.updateSharingType()
    }

    func setClickThrough(_ passThrough: Bool) {
        ignoresMouseEvents = passThrough
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
            ZStack {
                // Layer 0: full-screen dismiss tap target (only active when expanded)
                Color.black.opacity(isExpanded ? 0.001 : 0)
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(isExpanded)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            isExpanded = false
                        }
                    }

                // Layer 1: widget pinned to bottom-centre
                VStack {
                    Spacer()
                    LiquidGlassMusicWidget(
                        isExpanded: $isExpanded,
                        artNamespace: artNamespace,
                        onArtFrameChange: { frame in
                            AlbumArtHitRegion.shared.frameInWindow = frame
                        }
                    )
                        .compositingGroup()
                        .shadow(color: .black.opacity(isExpanded ? 0.5 : 0), radius: isExpanded ? 60 : 0, x: 0, y: isExpanded ? 20 : 0)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity),
                                removal:   .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
                            )
                        )
                        .allowsHitTesting(true)
                    Spacer().frame(height: isExpanded ? 115 : 210)
                }
                .frame(width: geo.size.width)

                // Layer 2: expanded album art
                if isExpanded {
                    let artSize = min(geo.size.width, geo.size.height) * 0.42
                    ExpandedAlbumArtView(isExpanded: $isExpanded, artNamespace: artNamespace)
                        .frame(width: artSize, height: artSize)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.6), radius: 60, x: 0, y: 20)
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.48)
                        .allowsHitTesting(true)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .coordinateSpace(name: "widgetRootSpace")
        }
        .ignoresSafeArea()
            .onReceive(NotificationCenter.default.publisher(for: .albumArtHitRegionTapped)) { _ in
                guard !isExpanded, Defaults[.lockScreenExpandedAlbumArt] else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    isExpanded = true
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isExpanded)
            .onChange(of: isExpanded) { _, expanded in
                if expanded {
                    AlbumArtBackgroundWindowController.shared.show()
                    NotificationCenter.default.post(name: .lockScreenProfileShouldHide, object: nil)
                    if Defaults[.keepAwakeOnExpandedArt] {
                        DisplaySleepPreventer.shared.acquire()
                    }
                } else {
                    AlbumArtBackgroundWindowController.shared.hide()
                    NotificationCenter.default.post(name: .lockScreenProfileShouldShow, object: nil)
                    DisplaySleepPreventer.shared.release()
                }
            }
            .onReceive(
                DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            ) { _ in
                if isExpanded {
                    isExpanded = false
                    // AlbumArtBackgroundWindowController is handled by KnotchApp.onScreenUnlocked
                    // via hideForUnlock(). The onChange(isExpanded: false) below will call hide()
                    // as a no-op safety net — that's fine. Don't call it explicitly here too.
                    NotificationCenter.default.post(name: .lockScreenProfileShouldShow, object: nil)
                }
            }
    }
}

// MARK: - Controller

/// NSHostingView that accepts the very first click even while its window
/// can't become key (KnotchSkyLightWindow always returns canBecomeKey == false).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class LiquidGlassWidgetWindowController {
    static let shared = LiquidGlassWidgetWindowController()
    private var window: LiquidGlassWidgetWindow?
    private var clickMonitor: Any?

    private init() {}

    // MARK: Show

    func show(on screen: NSScreen) {
        if window == nil {
            let win = LiquidGlassWidgetWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.contentView = FirstMouseHostingView(rootView: LiquidGlassWidgetRoot())
            window = win
        }

        guard let win = window else { return }
        win.setFrame(screen.frame, display: false)
        win.enableSkyLight()
        win.orderFrontRegardless()
        installClickMonitor()
    }

    func hide() {
        guard let win = window else { return }
        removeClickMonitor()
        win.disableSkyLight()
        win.orderOut(nil)
    }

    func setClickThrough(_ passThrough: Bool) {
        window?.setClickThrough(passThrough)
    }

    func updateScreen(_ screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
    }

    // MARK: - Direct hit-testing bypass for the album art thumbnail

    private func installClickMonitor() {
        guard clickMonitor == nil, let win = window else { return }

        // Local monitor: fires for events dispatched to our own windows
        // regardless of whether Knotch is the frontmost/active app, which
        // is what we need here since loginwindow is frontmost during lock.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak win] event in
            guard let win, event.window === win else { return event }
            let region = AlbumArtHitRegion.shared.frameInWindow
            guard region != .zero else { return event }

            // NSEvent.locationInWindow is bottom-left-origin AppKit coordinates;
            // AlbumArtHitRegion stores a top-left-origin SwiftUI frame — flip Y.
            let windowHeight = win.frame.height
            let point = CGPoint(x: event.locationInWindow.x, y: windowHeight - event.locationInWindow.y)

            if region.contains(point) {
                NotificationCenter.default.post(name: .albumArtHitRegionTapped, object: nil)
                return nil
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
