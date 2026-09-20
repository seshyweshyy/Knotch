//
//  NotchTransition.swift
//  Knotch
//
//  Pops each live activity (AirDrop, Tray, ...) in and out with a "squish and
//  blur" — scaled down on both axes, blurred, faded, with a vertical offset
//  compensating for the notch's own height change — instead of a plain fade
//  or slide. Used for the compact drag-and-drop overlay's own
//  appearance/disappearance.
//

import SwiftUI

struct BlurFadeModifier: ViewModifier {
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
            .compositingGroup()
    }
}

struct NotchPopModifier: ViewModifier {
    var blur: CGFloat = 0
    var opacity: Double = 1
    var offsetY: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    let anchor: UnitPoint
    // When > 0, clips the result (after the blur) to a rect with rounded
    // bottom corners of this radius, so the blur's haze can't spill past the
    // shape it sits in. Must be the same for a transition's active and
    // identity modifiers, so the view structure doesn't change mid-animation.
    var bottomClipRadius: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        let popped = content
            .scaleEffect(x: scaleX, y: scaleY, anchor: anchor)
            .offset(y: offsetY)
            .blur(radius: blur)
            .opacity(opacity)
            .compositingGroup()
        if bottomClipRadius > 0 {
            popped.clipShape(UnevenRoundedRectangle(
                bottomLeadingRadius: bottomClipRadius,
                bottomTrailingRadius: bottomClipRadius,
                style: .circular
            ))
        } else {
            popped
        }
    }
}

extension AnyTransition {
    static var blurAndFade: AnyTransition {
        .modifier(
            active: BlurFadeModifier(blur: 20, opacity: 0),
            identity: BlurFadeModifier(blur: 0, opacity: 1)
        )
    }

    /// Compact-presentation live-activity transition — squished to 0.4x/0.2y,
    /// blurred by 20pt, faded out, anchored center. Pair with
    /// `liveActivityPopSpring` via `.animation(_:value:)`.
    static var liveActivityPop: AnyTransition {
        .modifier(
            active: NotchPopModifier(blur: 20, opacity: 0, scaleX: 0.4, scaleY: 0.2, anchor: .center),
            identity: NotchPopModifier(anchor: .center)
        )
    }

    /// How the closed live activity leaves when the notch opens (see
    /// ClosedNotchRowContent's openingOffsetY/rowScaleY/blur/opacity): sent
    /// 14pt straight down into the growing shape, squashed to 0.88y,
    /// blurred by 6pt and faded — on rowFadeOutOnOpenSpring, which is much
    /// quicker than the shape's own open spring since the new content is
    /// already revealing on top of it.
    static var liveActivityOpenExit: AnyTransition {
        .modifier(
            active: NotchPopModifier(blur: 6, opacity: 0, offsetY: 14, scaleY: 0.88, anchor: .center),
            identity: NotchPopModifier(anchor: .center)
        )
        .animation(rowFadeOutOnOpenSpring)
    }

    /// The reveal Compact/Standard mode's open content uses (see ContentView's
    /// compactContentOverlay/standardContentOverlay) — scaled up from 0.6x
    /// out of the top edge, blurred by 30pt, faded in. Pair with
    /// `notchOpenSpring`/`notchCloseSpring`. The blur spreads past the
    /// shape's edge, so this clips the view's bottom corners to
    /// `bottomCornerRadius` afterwards.
    static func notchOpenReveal(bottomCornerRadius: CGFloat) -> AnyTransition {
        .modifier(
            active: NotchPopModifier(
                blur: 30, opacity: 0, scaleX: 0.6, scaleY: 0.6, anchor: .top,
                bottomClipRadius: bottomCornerRadius
            ),
            identity: NotchPopModifier(anchor: .top, bottomClipRadius: bottomCornerRadius)
        )
    }
}
