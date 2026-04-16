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
import Defaults

// MARK: - Window

class AlbumArtBackgroundWindow: BoringNotchSkyLightWindow {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        isMovable = false
        sharingType = .none
    }
}

// MARK: - Background View

enum LockScreenClockStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case solid = "Solid"
    case liquidGlass = "Liquid Glass"
    var id: String { rawValue }
}

private struct LockScreenClockView: View {
    let style: LockScreenClockStyle

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timeString: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current)
        let result = f.string(from: now)
        return result.replacingOccurrences(of: " am", with: "")
                     .replacingOccurrences(of: " pm", with: "")
                     .replacingOccurrences(of: "am", with: "")
                     .replacingOccurrences(of: "pm", with: "")
                     .trimmingCharacters(in: .whitespaces)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: now)
    }

    var body: some View {
        VStack(spacing: -10) {
            Text(dateString)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(style == .solid ? .white : .white.opacity(0.85))

            Text(timeString)
                .font(.system(size: 120, weight: .bold, design: .default))
                .foregroundStyle(
                    style == .solid
                        ? AnyShapeStyle(.white)
                        : AnyShapeStyle(.ultraThinMaterial)
                )
                .shadow(
                    color: style == .solid ? .black.opacity(0.2) : .clear,
                    radius: 6, x: 0, y: 2
                )
        }
        .onReceive(timer) { now = $0 }
    }
}

private struct AlbumArtBackgroundView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var colors: [Color] = [.black, .gray, .black]
    @Default(.lockScreenClockStyle) var clockStyle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: colors[0], location: 0),
                        .init(color: colors[safe: 1, fallback: colors[0]], location: 0.5),
                        .init(color: colors[safe: 2, fallback: colors[0]], location: 1.0),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(Color.black.opacity(0.1))
                .ignoresSafeArea()
                .overlay(
                    RadialGradient(
                        colors: [colors[0].opacity(0.3), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 400
                    )
                )
                // Fake lock screen clock — sits in upper-centre, above the gradient
                VStack {
                    Spacer().frame(height: geo.size.height * 0.08)
                    LockScreenClockView(style: clockStyle)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
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
        win.enableSkyLight()
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
            win.disableSkyLight()
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
