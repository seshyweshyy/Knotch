//
//  BlurTransition.swift
//  Knotch
//

import SwiftUI

private struct BlurTransitionModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    // Blurs content in/out on mount/unmount, for pairing with .scale/.opacity
    // transitions on views that appear or disappear with the notch's open/close
    // animation (distinct from the gesture-driven liquidBlurRadius).
    static func blur(radius: CGFloat) -> AnyTransition {
        .modifier(
            active: BlurTransitionModifier(radius: radius),
            identity: BlurTransitionModifier(radius: 0)
        )
    }
}
