//
//  VolumeHUDLottieView.swift
//  Knotch
//
//  Created by Seshan Engunan on 30/4/2026.
//


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
// SwiftUI wrapper — renders at displaySize, Lottie fills it via Auto Layout
struct VolumeHUDLottieView: View {
    let value: CGFloat
    let displaySize: CGFloat   // the visual size you want on screen

    var body: some View {
        _VolumeHUDLottieNSView(value: value)
            .frame(width: displaySize, height: displaySize)
    }
}

private struct _VolumeHUDLottieNSView: NSViewRepresentable {
    let value: CGFloat

    private static let totalFrames: CGFloat = 105

    private var lottieProgress: CGFloat {
        if value == 0          { return 0 }
        if value <= 0.33       { return 35 / Self.totalFrames }
        if value <= 0.66       { return 55 / Self.totalFrames }
        return                           75 / Self.totalFrames
    }

    func makeNSView(context: Context) -> NSView {
        let lottie = LottieAnimationView(name: "volume_animation")
        lottie.contentMode = .scaleAspectFit
        lottie.loopMode = .playOnce
        lottie.wantsLayer = true
        lottie.translatesAutoresizingMaskIntoConstraints = false
        lottie.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lottie.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        lottie.currentProgress = lottieProgress

        let container = NSView()
        container.wantsLayer = true
        container.addSubview(lottie)
        NSLayoutConstraint.activate([
            lottie.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lottie.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lottie.topAnchor.constraint(equalTo: container.topAnchor),
            lottie.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let lottie = nsView.subviews.first as? LottieAnimationView else { return }
        let target = lottieProgress
        guard abs(target - lottie.currentProgress) > 0.001 else { return }
        lottie.animationSpeed = 1.8
        lottie.play(
            fromProgress: lottie.currentProgress,
            toProgress: target,
            loopMode: .playOnce,
            completion: nil
        )
    }
}

// MARK: - Display HUD Lottie View

struct DisplayHUDLottieView: View {
    let displaySize: CGFloat

    var body: some View {
        _DisplayHUDLottieNSView()
            .frame(width: displaySize, height: displaySize)
    }
}

private struct _DisplayHUDLottieNSView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let lottie = LottieAnimationView(name: "display_animation")
        lottie.contentMode = .scaleAspectFit
        lottie.loopMode = .loop
        lottie.animationSpeed = 1.0
        lottie.wantsLayer = true
        lottie.translatesAutoresizingMaskIntoConstraints = false
        lottie.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lottie.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        lottie.play()

        let container = NSView()
        container.wantsLayer = true
        container.addSubview(lottie)
        NSLayoutConstraint.activate([
            lottie.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lottie.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lottie.topAnchor.constraint(equalTo: container.topAnchor),
            lottie.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let lottie = nsView.subviews.first as? LottieAnimationView else { return }
        if !lottie.isAnimationPlaying { lottie.play() }
    }
}
