//
//  VolumeHUDLottieView.swift
//  Knotch
//

import SwiftUI
import Lottie

/// Drives the volume Lottie animation by scrubbing `currentProgress`
/// based on the volume value. Thresholds match the JSON timeline:
///   0.00 = muted  (frame 0)
///   0.33 = wave 1 (frame 35/105)
///   0.66 = wave 2 (frame 55/105)
///   1.00 = wave 3 (frame 105/105)
struct VolumeHUDLottieView: NSViewRepresentable {
    let value: CGFloat   // 0.0 (muted) → 1.0 (full)
    let size: CGFloat

    // Total meaningful frames in the JSON
    private static let totalFrames: CGFloat = 105

    // Map volume → Lottie progress (0.0–1.0)
    private var lottieProgress: CGFloat {
        if value == 0 {
            return 0                          // muted — frame 0
        } else if value <= 0.33 {
            return 35 / Self.totalFrames      // wave 1 settled
        } else if value <= 0.66 {
            return 55 / Self.totalFrames      // wave 2 settled
        } else {
            return 75 / Self.totalFrames      // wave 3 settled
        }
    }

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView(name: "Apple_Volume_Icon_v7")
        view.contentMode = .scaleAspectFit
        view.loopMode = .playOnce
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // Set initial progress without animation
        view.currentProgress = lottieProgress
        return view
    }

    func updateNSView(_ nsView: LottieAnimationView, context: Context) {
        let target = lottieProgress
        guard target != nsView.currentProgress else { return }

        // Animate to the target frame with a spring-like duration
        nsView.play(
            fromProgress: nsView.currentProgress,
            toProgress: target,
            loopMode: .playOnce,
            completion: nil
        )
    }
}