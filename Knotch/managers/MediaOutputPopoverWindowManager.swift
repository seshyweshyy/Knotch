//
//  MediaOutputPopoverWindowManager.swift
//  Knotch
//

import AppKit
import SwiftUI

// Captures the NSView backing a SwiftUI view so its on-screen frame can be
// read later (SwiftUI's own coordinate spaces are window-local, not screen).
struct PopoverAnchorView: NSViewRepresentable {
    let onCapture: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onCapture(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Custom replacement for SwiftUI's `.popover()` for anchors living in
// KnotchWindow. KnotchWindow.canBecomeKey is always false (it must never
// steal focus), and NSPopover's close fade relies on the standard key-window
// resignation flow — attached to a window that can never become key, it just
// orders out instantly instead of animating. This drives the same open/close
// fade manually so it always plays regardless of window key status.
@MainActor
final class MediaOutputPopoverWindowManager {
    static let shared = MediaOutputPopoverWindowManager()

    private var panel: MediaOutputPopoverPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var anchorFrameOnScreen: CGRect = .zero
    // The visible card's own frame, smaller than the panel's window frame
    // (which is padded to give the card's shadow room to bleed) — used for
    // outside-click detection so a click in that transparent shadow margin
    // still dismisses instead of being treated as "inside the popover".
    private var visibleCardFrameOnScreen: CGRect = .zero

    private init() {}

    func show(
        anchorView: NSView,
        routeManager: AudioRouteManager,
        volumeModel: MediaOutputVolumeViewModel,
        onDismiss: @escaping () -> Void
    ) {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil

        guard let anchorWindow = anchorView.window else { return }
        anchorFrameOnScreen = anchorWindow.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))

        let cornerRadius: CGFloat = 22
        // Extra margin around the card so its own SwiftUI `.shadow(...)` (radius
        // 30, y offset 12) has room to bleed into — without it, either this view's
        // own bounds or the window's frame clips the shadow to a hard rectangle.
        let shadowPadding: CGFloat = 50
        let card = chromedContent(
            cornerRadius: cornerRadius,
            routeManager: routeManager,
            volumeModel: volumeModel,
            onDismiss: onDismiss
        )

        let hosting = NSHostingView(rootView: card.padding(shadowPadding))
        let paddedSize = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: paddedSize)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let cardSize = CGSize(
            width: paddedSize.width - shadowPadding * 2,
            height: paddedSize.height - shadowPadding * 2
        )
        let gap: CGFloat = 8
        let cardOrigin = CGPoint(
            x: anchorFrameOnScreen.midX - cardSize.width / 2,
            y: anchorFrameOnScreen.minY - gap - cardSize.height
        )
        visibleCardFrameOnScreen = CGRect(origin: cardOrigin, size: cardSize)
        let windowOrigin = CGPoint(x: cardOrigin.x - shadowPadding, y: cardOrigin.y - shadowPadding)

        let newPanel = MediaOutputPopoverPanel()
        newPanel.contentView = hosting
        newPanel.setFrame(CGRect(origin: windowOrigin, size: paddedSize), display: false)
        // The fade is done via the content layer's opacity, not the window's
        // alphaValue — NSWindow.animator().alphaValue silently stops animating
        // once the window is added to the CGSSpace overlay below (it just
        // jumps to the end value), since that overlay isn't a normal
        // WindowServer-managed space transition. A CALayer opacity animation
        // is driven by Core Animation directly and isn't affected by that.
        newPanel.alphaValue = 1
        hosting.layer?.opacity = 0
        newPanel.orderFrontRegardless()
        panel = newPanel
        // Same synthetic always-on-top CGSSpace the main notch window joins
        // (NotchSpaceManager) — plain collectionBehavior still gets swapped
        // out and back in per-desktop during a live Mission Control swipe,
        // which reads as a hide/show flicker. Membership in this overlay
        // space keeps it composited above the swipe animation the whole time.
        NotchSpaceManager.shared.notchSpace.windows.insert(newPanel)

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = fadeDuration
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hosting.layer?.add(fadeIn, forKey: "fadeIn")
        hosting.layer?.opacity = 1

        installMonitors(onDismiss: onDismiss)
    }

    func hide() {
        removeMonitors()
        guard let panelToHide = panel else { return }
        panel = nil

        guard let layer = panelToHide.contentView?.layer else {
            panelToHide.orderOut(nil)
            panelToHide.contentView = nil
            NotchSpaceManager.shared.notchSpace.windows.remove(panelToHide)
            return
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            panelToHide.orderOut(nil)
            panelToHide.contentView = nil
            NotchSpaceManager.shared.notchSpace.windows.remove(panelToHide)
        }
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = fadeDuration
        fadeOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        layer.add(fadeOut, forKey: "fadeOut")
        layer.opacity = 0
        CATransaction.commit()
    }

    private let fadeDuration: CFTimeInterval = 0.16

    // Matches LiquidGlassMusicWidget's chrome exactly: the glass effect (or its
    // material fallback) and the rounding clipShape are chained directly onto
    // the real content, not tucked behind it as a `.background()` — a glass
    // effect applied to a decorative placeholder view sitting in the
    // background doesn't pick up the clip, and renders with square corners.
    @ViewBuilder
    private func chromedContent(
        cornerRadius: CGFloat,
        routeManager: AudioRouteManager,
        volumeModel: MediaOutputVolumeViewModel,
        onDismiss: @escaping () -> Void
    ) -> some View {
        let base = MediaOutputSelectorPopover(
            routeManager: routeManager,
            volumeModel: volumeModel,
            onHoverChanged: { _ in },
            dismiss: onDismiss
        )
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                base
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
            }
        } else {
            base
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thickMaterial)
                        .environment(\.colorScheme, .dark)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
        }
    }

    private func installMonitors(onDismiss: @escaping () -> Void) {
        let anchorFrame = anchorFrameOnScreen
        let cardFrame = visibleCardFrameOnScreen
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard self?.panel != nil, let window = event.window else { return event }
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            // Clicks on the visible card are handled by its own content; clicks on
            // the toggle button are left for its own tap gesture, which already
            // flips the same state this monitor would flip — handling both would
            // race the two. A click in the transparent shadow margin around the
            // card (still within the panel's own padded window frame) falls
            // through neither check, so it correctly dismisses like any other
            // outside click.
            if cardFrame.contains(screenPoint) || anchorFrame.contains(screenPoint) {
                return event
            }
            onDismiss()
            return event
        }
        // Global monitor only reports events in *other* applications, so any hit here
        // is unambiguously outside — no anchor/panel check needed.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard self?.panel != nil else { return }
            onDismiss()
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
    }
}

private final class MediaOutputPopoverPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        // Off, not true — a native window shadow is computed from the content's
        // rendered shape but doesn't keep re-syncing while a raw CALayer opacity
        // animation runs outside AppKit's normal display cycle, so its edge stays
        // frozen at full strength while the fill fades out underneath it (visible
        // as a hard outline during the fade). Shadow is drawn in SwiftUI instead,
        // baked into the same layer that's actually animating — see chromedContent.
        hasShadow = false
        // Strictly above KnotchWindow/KnotchSkyLightWindow's own `.mainMenu + 3` —
        // sharing the same level left the stacking order to whichever window was
        // last ordered front, so anything that re-fronts the notch mid-fade (e.g.
        // its own glass-backdrop refresh) could drop this panel behind it while
        // it's closing.
        level = .mainMenu + 4
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        isReleasedWhenClosed = false
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
