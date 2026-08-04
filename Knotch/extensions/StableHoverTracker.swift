//
//  StableHoverTracker.swift
//  Knotch
//

import AppKit
import SwiftUI

// SwiftUI's .onHover is backed by a tracking area on the view it's attached to,
// and can drop/re-register mid-gesture when that view re-renders (e.g. the
// calendar day scroller re-rendering on every scroll position change while the
// user is actively swiping through it) — which is what let scroll events
// occasionally leak through to the notch's own gesture handlers. This wraps a
// plain NSView whose identity doesn't change with the content above it, so its
// NSTrackingArea stays installed for the whole gesture instead of blinking.
struct StableHoverTracker: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }

    // Switching tabs (home -> tray) or closing the notch unmounts this view
    // entirely — if the cursor was over the wheel at that moment, nothing would
    // otherwise fire mouseExited to clear the hover flag, leaving it stuck true
    // and blocking gestures on whatever's shown next.
    static func dismantleNSView(_ nsView: TrackingNSView, coordinator: ()) {
        nsView.reset()
    }

    final class TrackingNSView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isHovering = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area

            // updateTrackingAreas() re-fires on every geometry change, including
            // each tick of the notch's open/close spring animation as this view's
            // frame is resized into place. AppKit's own mouseEntered/mouseExited
            // synthesis for a moving tracking area only reflects the cursor
            // position at the instant the area changed — if the cursor sits still
            // while the frame animates out from under it, no further event ever
            // fires, so hover state can get stuck true (blocking gestures) after
            // the animation settles. Re-deriving from the live cursor position
            // here on every recomputation keeps it self-correcting instead.
            setHovering(currentMouseIsInsideBounds())
        }

        private func currentMouseIsInsideBounds() -> Bool {
            guard let window else { return false }
            let pointInWindow = window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            return bounds.contains(pointInView)
        }

        private func setHovering(_ hovering: Bool) {
            guard hovering != isHovering else { return }
            isHovering = hovering
            onHoverChange?(hovering)
        }

        func reset() {
            setHovering(false)
        }

        override func mouseEntered(with event: NSEvent) {
            setHovering(true)
        }

        override func mouseExited(with event: NSEvent) {
            setHovering(false)
        }
    }
}
