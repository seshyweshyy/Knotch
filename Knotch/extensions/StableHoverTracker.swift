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

    final class TrackingNSView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

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
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
        }
    }
}
