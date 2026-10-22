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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.85)
            .task {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(Double(index) * 0.07))
                } catch { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                    appeared = true
                }
            }
    }
}

extension View {
    func staggeredEntrance(_ index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }
}
