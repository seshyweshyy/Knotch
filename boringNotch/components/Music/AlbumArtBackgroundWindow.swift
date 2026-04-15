//
//  AlbumArtBackgroundWindow.swift
//  boringNotch
//
//  A low-level full-screen window that renders a blurred, animated album art
//  gradient behind the lock screen UI (clock, login) but above the wallpaper.
//  Shown only when the expanded album art view is active.
//

import AppKit
import SwiftUI
import Combine

// MARK: - Window

class AlbumArtBackgroundWindow: BoringNotchSkyLightWindow {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        isMovable = false
        sharingType = .none
    }
}

// MARK: - Background View

private struct AlbumArtBackgroundView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var colors: [Color] = [.black, .gray, .black]

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: colors[0].opacity(0.9), location: 0),
                    .init(color: colors[safe: 1, fallback: colors[0]].opacity(0.95), location: 0.5),
                    .init(color: colors[safe: 2, fallback: colors[0]], location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay(
                RadialGradient(
                    colors: [colors[0].opacity(0.3), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 400
                )
            )
        }
        .onChange(of: musicManager.artFlipSignal) { _, signal in
            signal.art.dominantColors(count: 3) { nsColors in
                withAnimation(.easeInOut(duration: 0.8)) {
                    colors = nsColors.map { Color(nsColor: $0).saturated(by: 1.4).darkened(by: 0.2) }
                }
            }
        }
        .onAppear {
            musicManager.albumArt.dominantColors(count: 3) { nsColors in
                withAnimation(.easeInOut(duration: 0.8)) {
                    colors = nsColors.map { Color(nsColor: $0).saturated(by: 1.4).darkened(by: 0.2) }
                }
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let albumArtBackgroundShouldShow = Notification.Name("albumArtBackgroundShouldShow")
    static let albumArtBackgroundShouldHide = Notification.Name("albumArtBackgroundShouldHide")
    static let lockScreenProfileShouldHide  = Notification.Name("lockScreenProfileShouldHide")
    static let lockScreenProfileShouldShow  = Notification.Name("lockScreenProfileShouldShow")
}

// MARK: - Controller

class AlbumArtBackgroundWindowController {
    static let shared = AlbumArtBackgroundWindowController()
    private var window: AlbumArtBackgroundWindow?
    private init() {}

    func prepare(on screen: NSScreen) {
        if window == nil {
            let win = AlbumArtBackgroundWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.contentView = NSHostingView(rootView: AlbumArtBackgroundView())
            window = win
        }
        window?.setFrame(screen.frame, display: false)
    }

    func show() {
        guard let win = window else { return }
        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            win.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            win.animator().alphaValue = 0
        }, completionHandler: {
            win.orderOut(nil)
        })
    }

    func updateScreen(_ screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
    }
}

// MARK: - Array safe subscript
private extension Array {
    subscript(safe index: Int, fallback fallback: Element) -> Element {
        indices.contains(index) ? self[index] : fallback
    }
}

// MARK: - Color helpers
private extension Color {
    func saturated(by factor: CGFloat) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s * factor, 1), brightness: b, opacity: a)
    }

    func darkened(by amount: CGFloat) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: s, brightness: max(b - amount, 0), opacity: a)
    }
}
