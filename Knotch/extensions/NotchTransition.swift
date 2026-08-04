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

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scaleX, y: scaleY, anchor: anchor)
            .offset(y: offsetY)
            .blur(radius: blur)
            .opacity(opacity)
            .compositingGroup()
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
}
