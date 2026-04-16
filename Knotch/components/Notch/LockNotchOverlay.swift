//
//  LockNotchOverlay.swift
//  boringNotch
//
//  Lock icon that appears inside the closed notch when the
//  screen is locked.  When unlocked it plays a smooth scale+fade transition
//  back to the normal notch appearance.
//

import SwiftUI

// MARK: - Lock state icon

/// Renders the SF-Symbol lock icon centered inside the closed notch pill.
/// Animates between locked (lock.fill) and a brief unlocked flash (lock.open.fill)
/// before fading out entirely, mirroring Alcove's behaviour.
struct LockNotchOverlay: View {
    let isLocked: Bool
    @Binding var isUnlockAnimating: Bool

    var body: some View {
        Group {
            if isLocked || isUnlockAnimating {
                Image(systemName: isUnlockAnimating ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: isUnlockAnimating ? 14 : 13, weight: .semibold))
                    .foregroundStyle(
                        isUnlockAnimating
                            ? Color.white.opacity(0.85)
                            : Color.white.opacity(0.75)
                    )
                    .scaleEffect(isUnlockAnimating ? 0.9 : 1.0)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity),
                            removal: .scale(scale: 0.6).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: isLocked)
        .animation(.spring(response: 0.30, dampingFraction: 0.65), value: isUnlockAnimating)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var locked = true
        @State private var isUnlockAnimating = false
        var body: some View {
            ZStack {
                Color.black
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(width: 185, height: 38)
                LockNotchOverlay(isLocked: locked, isUnlockAnimating: $isUnlockAnimating)
            }
            .frame(width: 300, height: 80)
            .background(Color.gray.opacity(0.2))
            .onTapGesture { locked.toggle() }
        }
    }
    return PreviewWrapper()
}

