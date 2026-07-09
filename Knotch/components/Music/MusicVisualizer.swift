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

    private let barWidth: CGFloat = 2
    private let barCount = 5
    private let spacing: CGFloat = 2
    private let totalHeight: CGFloat = 14
    
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
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            // Frame is always full height and never moves — only the path shape changes
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            let initialScale = CGFloat.random(in: 0.35...1.0)
            barLayer.path = barPath(scale: initialScale)
            barLayer.transform = CATransform3DMakeScale(1, initialScale, 1)
            barLayers.append(barLayer)
            barScales.append(initialScale)
            layer?.addSublayer(barLayer)
        }
    }

    // Builds a vertically-centered rounded rect path within the full totalHeight frame
    private func barPath(scale: CGFloat) -> CGPath {
        // Path always full height — scale.y transform handles size, path stays constant
        return NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                            xRadius: barWidth / 2,
                            yRadius: barWidth / 2).cgPath
    }
    
    private func startAnimating() {
        guard animationTimer == nil else { return }
        if #available(macOS 14.2, *) {
            // Fire one immediate random frame so there's no blank gap on start
            updateBars(amplitudes: nil)
            meterCancellable = LiveAudioMeter.shared.$amplitudes
                .receive(on: DispatchQueue.main)
                .throttle(for: .milliseconds(70), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] amplitudes in
                    guard let self, self.currentIsPlaying else { return }
                    let hasSignal = amplitudes.contains { $0 > 0.01 }
                    self.updateBars(amplitudes: hasSignal ? amplitudes : nil)
                }
            // Only run the fallback timer if the live meter has no signal
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
                guard let self else { return }
                let hasSignal = LiveAudioMeter.shared.amplitudes.contains { $0 > 0.01 }
                if hasSignal { return }
                self.updateBars(amplitudes: nil)
            }
        } else {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.19, repeats: true) { [weak self] _ in
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
            for (i, barLayer) in barLayers.enumerated() {
                let currentScale = barScales[i]
                let targetScale: CGFloat
                if let amplitudes, i < amplitudes.count {
                    let dotScale: CGFloat = 2.0 / 14.0
                    let clamped = CGFloat(min(1.0, amplitudes[i]))
                    targetScale = max(dotScale, clamped)
                    barScales[i] = targetScale
                    // Snap path instantly — spring morphing causes bezier warping
                    let spring = CASpringAnimation(keyPath: "transform.scale.y")
                    spring.fromValue = (barLayer.presentation() ?? barLayer).value(forKeyPath: "transform.scale.y") ?? currentScale
                    spring.toValue = targetScale
                    spring.mass = 0.12
                    spring.stiffness = 380
                    spring.damping = 8
                    spring.initialVelocity = 0
                    spring.fillMode = .forwards
                    spring.isRemovedOnCompletion = false
                    spring.duration = spring.settlingDuration
                    barLayer.add(spring, forKey: "scaleY")
                    barLayer.transform = CATransform3DMakeScale(1, targetScale, 1)
                } else {
                    let t = CGFloat(i) / CGFloat(barCount - 1)
                    let maxScale = 1.0 - (t * 0.15)
                    let minScale = 0.15 + (t * 0.05)
                    let rawTarget = CGFloat.random(in: minScale...maxScale)
                    targetScale = currentScale * 0.2 + rawTarget * 0.8
                    barScales[i] = targetScale
                    let anim = CABasicAnimation(keyPath: "transform.scale.y")
                    anim.fromValue = (barLayer.presentation() ?? barLayer).value(forKeyPath: "transform.scale.y") ?? currentScale
                    anim.toValue = targetScale
                    anim.duration = 0.21
                    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    anim.fillMode = .forwards
                    anim.isRemovedOnCompletion = false
                    barLayer.add(anim, forKey: "scaleY")
                    barLayer.transform = CATransform3DMakeScale(1, targetScale, 1)
                }
            }
        }
    
    private func resetBars() {
        let dotScale: CGFloat = 2.0 / 14.0
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            let anim = CABasicAnimation(keyPath: "transform.scale.y")
            anim.fromValue = (barLayer.presentation() ?? barLayer).value(forKeyPath: "transform.scale.y") ?? barScales[i]
            anim.toValue = dotScale
            anim.duration = 0.25
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            barLayer.add(anim, forKey: "scaleY")
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
