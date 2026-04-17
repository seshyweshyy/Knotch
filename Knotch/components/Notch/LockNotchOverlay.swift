//
//  LockNotchOverlay.swift
//  boringNotch
//
//  Lock icon that appears inside the closed notch when the
//  screen is locked.  When unlocked it plays a smooth scale+fade transition
//  back to the normal notch appearance.
//

import SwiftUI
import Lottie

struct LockNotchOverlay: View {
    let isLocked: Bool
    @Binding var isUnlockAnimating: Bool

    @State private var playForward: Bool = false

    var body: some View {
        Group {
            if isLocked || isUnlockAnimating {
                LottieAnimationViewRepresentable(playForward: playForward) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.70)) {
                        isUnlockAnimating = false
                    }
                }
                .frame(width: 32, height: 18)
                .offset(x: -8)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.7).combined(with: .opacity),
                            removal:   .scale(scale: 0.7).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.70), value: isLocked)
        .animation(.spring(response: 0.32, dampingFraction: 0.70), value: isUnlockAnimating)
        .onChange(of: isLocked) { _, locked in
            playForward = !locked
        }
    }
}

// MARK: - NSViewRepresentable wrapper

private struct LottieAnimationViewRepresentable: NSViewRepresentable {
    let playForward: Bool
    var onComplete: (() -> Void)? = nil

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView(name: "lock-unlock")
        view.contentMode = .scaleAspectFit
        view.loopMode = .playOnce
        view.animationSpeed = 1.4
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: LottieAnimationView, context: Context) {
        nsView.frame = CGRect(origin: .zero, size: CGSize(width: 32, height: 18))
        if playForward {
            nsView.play(fromFrame: 0, toFrame: 90, loopMode: .playOnce) { finished in
                if finished { onComplete?() }
            }
        } else {
            nsView.play(fromFrame: 90, toFrame: 0, loopMode: .playOnce) { finished in
                if finished { onComplete?() }
            }
        }
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
            .onTapGesture {
                locked.toggle()
                isUnlockAnimating = !locked
                if !locked {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        isUnlockAnimating = false
                    }
                }
            }
        }
    }
    return PreviewWrapper()
}
