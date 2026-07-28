//
//  LockNotchOverlay.swift
//  Knotch
//
//  Lock icon that appears inside the closed notch when the
//  screen is locked.  When unlocked it plays a smooth scale+fade transition
//  back to the normal notch appearance.
//

import SwiftUI
import Lottie

final class LockAnimationHost: ObservableObject {
    let animationView: LottieAnimationView = {
        let v = LottieAnimationView(name: "lock-unlock")
        v.contentMode = .scaleAspectFit
        v.loopMode = .playOnce
        v.animationSpeed = 2.8
        v.wantsLayer = true
        v.layer?.masksToBounds = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }()

    func play(forward: Bool, onComplete: (() -> Void)? = nil) {
        guard !animationView.isAnimationPlaying else { return }
        if forward {
            animationView.play(fromFrame: 0, toFrame: 90, loopMode: .playOnce) { finished in
                if finished { onComplete?() }
            }
        } else {
            animationView.play(fromFrame: 90, toFrame: 0, loopMode: .playOnce) { finished in
                if finished { onComplete?() }
            }
        }
    }
}

struct LockNotchOverlay: View {
    let isLocked: Bool
    @Binding var isUnlockAnimating: Bool
    let host: LockAnimationHost

    var body: some View {
        Group {
            if isLocked || isUnlockAnimating {
                LottieAnimationViewRepresentable(animationView: host.animationView)
                    .frame(width: 20, height: 20)
                    .offset(x: -5, y: -1)
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
        // Playing/resetting used to happen here, but this view is only
        // mounted while the closed-notch row is actually showing the lock
        // icon (ClosedRowFamily == .lock) — a HUD taking over the row at
        // the wrong moment could unmount it before a lock/unlock transition
        // finished, dropping the reset. KnotchApp.onScreenLocked and
        // ContentView's own (always-mounted) onChange(of: vm.isScreenLocked)
        // now drive host.play(...) directly instead — see there.
    }
}

private struct LottieAnimationViewRepresentable: NSViewRepresentable {
    let animationView: LottieAnimationView

    func makeNSView(context: Context) -> LottieAnimationView { animationView }
    func updateNSView(_ nsView: LottieAnimationView, context: Context) {
        nsView.frame = CGRect(origin: .zero, size: CGSize(width: 20, height: 20))
        // intentionally empty — all play calls go through LockAnimationHost.play()
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
                LockNotchOverlay(isLocked: locked, isUnlockAnimating: $isUnlockAnimating, host: LockAnimationHost())
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
