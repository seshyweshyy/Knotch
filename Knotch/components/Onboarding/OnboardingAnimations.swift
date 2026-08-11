//
//  OnboardingAnimations.swift
//  Knotch
//

import SwiftUI

// Staggers an element's fade + scale entrance after its parent screen appears.
// No offset/slide here — the screen-level push transition already handles vertical motion.
private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.85)
            .onAppear {
                // Deferred a tick so this starts its own transaction instead of merging into the parent's.
                DispatchQueue.main.async {
                    withAnimation(
                        .spring(response: 0.5, dampingFraction: 0.75)
                            .delay(Double(index) * 0.07)
                    ) {
                        appeared = true
                    }
                }
            }
    }
}

extension View {
    func staggeredEntrance(_ index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }
}
