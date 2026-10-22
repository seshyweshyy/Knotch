//
//  LottieView.swift
//  Knotch
//
//  Created by Alexander on 2025-11-14.
//

import SwiftUI
import Lottie

struct LottieView: NSViewRepresentable {
    let url: URL
    let speed: Double
    let loopMode: LottieLoopMode

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class Coordinator {
        var url: URL?
        var speed: CGFloat = 1
        var loopMode: LottieLoopMode = .loop
        var reduceMotion = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let animationView = LottieAnimationView()
        animationView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            animationView.topAnchor.constraint(equalTo: container.topAnchor),
            animationView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let animationView = nsView.subviews.first as? LottieAnimationView else { return }
        let coordinator = context.coordinator
        coordinator.speed = CGFloat(speed)
        coordinator.loopMode = loopMode
        coordinator.reduceMotion = reduceMotion
        animationView.loopMode = loopMode
        animationView.animationSpeed = CGFloat(speed)
        if coordinator.url != url {
            // Record the request before loading. Parent redraws must not start
            // duplicate loads, and an older response must not replace newer art.
            coordinator.url = url
            animationView.stop()
            LottieAnimation.loadedFrom(url: url) { [weak animationView, weak coordinator] animation in
                guard let animationView, let coordinator, coordinator.url == url else { return }
                animationView.animation = animation
                animationView.loopMode = coordinator.loopMode
                animationView.animationSpeed = coordinator.speed
                if !coordinator.reduceMotion { animationView.play() }
            }
        } else if reduceMotion {
            animationView.pause()
        } else if !animationView.isAnimationPlaying {
            animationView.play()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.url = nil
        (nsView.subviews.first as? LottieAnimationView)?.stop()
    }
}
