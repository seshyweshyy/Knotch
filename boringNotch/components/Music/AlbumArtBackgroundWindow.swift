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
    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var isVisible: Bool = false

    var body: some View {
        ZStack {
            Image(nsImage: displayedArt)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1.3)  // push art past all edges before blurring
                .blur(radius: 60)
                .saturation(1.8)
                .overlay(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: musicManager.artFlipSignal) { _, signal in
            withAnimation(.easeInOut(duration: 0.4)) {
                displayedArt = signal.art
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
