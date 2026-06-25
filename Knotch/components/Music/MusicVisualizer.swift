//
//  MusicVisualizer.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI
import Combine

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private(set) var currentIsPlaying: Bool = true
    private var animationTimer: Timer?
    private var meterCancellable: AnyCancellable?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 5
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            let initialScale = CGFloat.random(in: 0.35...1.0)
            barLayer.transform = CATransform3DMakeScale(1, initialScale, 1)
            barLayers.append(barLayer)
            barScales.append(initialScale)
            layer?.addSublayer(barLayer)
        }
    }
    
    private func startAnimating() {
            guard animationTimer == nil else { return }
            // Subscribe to live meter if available (macOS 14.2+)
            if #available(macOS 14.2, *) {
                meterCancellable = LiveAudioMeter.shared.$amplitudes
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] amplitudes in
                        guard let self, self.currentIsPlaying else { return }
                        self.updateBars(amplitudes: amplitudes)
                    }
                // Keep timer as fallback in case meter has no signal yet
                animationTimer = Timer.scheduledTimer(withTimeInterval: 0.21, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    // Only fire random animation if meter is silent (all zeros)
                    if #available(macOS 14.2, *) {
                        let hasSignal = LiveAudioMeter.shared.amplitudes.contains { $0 > 0.01 }
                        if hasSignal { return }
                    }
                    self.updateBars(amplitudes: nil)
                }
            } else {
                animationTimer = Timer.scheduledTimer(withTimeInterval: 0.21, repeats: true) { [weak self] _ in
                    self?.updateBars(amplitudes: nil)
                }
            }
        }
    
    private func stopAnimating() {
            meterCancellable?.cancel()
            meterCancellable = nil
            animationTimer?.invalidate()
            animationTimer = nil
            resetBars()
        }
    
    private func updateBars(amplitudes: [Float]?) {
            let barCount = barLayers.count
            for (i, barLayer) in barLayers.enumerated() {
                let currentScale = barScales[i]
                let targetScale: CGFloat
                if let amplitudes, i < amplitudes.count {
                    // Live audio path — spring animation, minimum is dot scale like resetBars()
                    let dotScale: CGFloat = 2.0 / 14.0
                    let clamped = CGFloat(min(1.0, amplitudes[i]))
                    targetScale = max(dotScale, clamped)
                    barScales[i] = targetScale
                    let spring = CASpringAnimation(keyPath: "transform.scale.y")
                    spring.fromValue = currentScale
                    spring.toValue = targetScale
                    spring.mass = 0.5
                    spring.stiffness = 120
                    spring.damping = 8
                    spring.initialVelocity = 0
                    spring.fillMode = .forwards
                    spring.isRemovedOnCompletion = false
                    spring.duration = spring.settlingDuration
                    barLayer.add(spring, forKey: "scaleY")
                } else {
                    // Random fallback path
                    targetScale = CGFloat.random(in: 0.1...0.7)
                    barScales[i] = targetScale
                    let animation = CABasicAnimation(keyPath: "transform.scale.y")
                    animation.fromValue = currentScale
                    animation.toValue = targetScale
                    animation.duration = 0.21
                    animation.autoreverses = false
                    animation.fillMode = .forwards
                    animation.isRemovedOnCompletion = false
                    if #available(macOS 13.0, *) {
                        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
                    }
                    barLayer.add(animation, forKey: "scaleY")
                }
            }
        }
    
    private func resetBars() {
        let dotScale: CGFloat = 2.0 / 14.0
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = barScales[i]
            animation.toValue = dotScale
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            barLayer.add(animation, forKey: "scaleY")
            barLayer.transform = CATransform3DMakeScale(1, dotScale, 1)
            barScales[i] = dotScale
        }
    }
    
    func setPlaying(_ playing: Bool) {
        currentIsPlaying = playing
        if currentIsPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AudioSpectrum {
        context.coordinator.spectrum.setPlaying(isPlaying)
        return context.coordinator.spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        guard nsView.currentIsPlaying != isPlaying else { return }
        nsView.setPlaying(isPlaying)
    }

    class Coordinator {
        let spectrum = AudioSpectrum()
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
