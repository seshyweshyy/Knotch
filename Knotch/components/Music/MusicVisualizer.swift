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

    // Single source of truth for the bar look. Every call site frames
    // AudioSpectrumView using `recommendedFrameSize` below instead of its own
    // hardcoded numbers, so changing these here is the only edit needed.
    //
    // To resize the whole waveform, change `scale` — it multiplies bar
    // width/spacing/height together instead of hand-balancing them separately.
    // `barCount` is discrete and stays untouched by scale.
    static let scale: CGFloat = 1.05
    private static let baseBarWidth: CGFloat = 2.2
    private static let baseSpacing: CGFloat = 0.9
    private static let baseTotalHeight: CGFloat = 16

    static var barWidth: CGFloat { baseBarWidth * scale }
    static let barCount = 6
    static var spacing: CGFloat { baseSpacing * scale }
    static var totalHeight: CGFloat { baseTotalHeight * scale }

    // Exact bar-row footprint at rest
    static var contentSize: CGSize {
        CGSize(width: CGFloat(barCount) * (barWidth + spacing), height: totalHeight)
    }

    // Content size plus headroom for the spring animation's overshoot
    // (CASpringAnimation can bounce past scale 1.0 momentarily), so loud
    // transients don't get clipped by a container sized to the resting bar height.
    static var recommendedFrameSize: CGSize {
        CGSize(width: contentSize.width + 4, height: contentSize.height + 4)
    }

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
        let totalWidth = CGFloat(Self.barCount) * (Self.barWidth + Self.spacing)
        frame.size = CGSize(width: totalWidth, height: Self.totalHeight)

        for i in 0 ..< Self.barCount {
            let xPosition = CGFloat(i) * (Self.barWidth + Self.spacing)
            let barLayer = CAShapeLayer()
            // Frame is always full height and never moves — only the path shape changes
            barLayer.frame = CGRect(x: xPosition, y: 0, width: Self.barWidth, height: Self.totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + Self.barWidth / 2, y: Self.totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            let initialScale = CGFloat.random(in: 0.35...1.0)
            barLayer.path = barPath(scale: initialScale)
            barLayer.transform = CATransform3DMakeScale(1, initialScale, 1)
            barLayers.append(barLayer)
            barScales.append(initialScale)
            layer?.addSublayer(barLayer)
        }
    }

    // Builds a vertically-centered rounded rect path within the full totalHeight frame.
    //
    // Bar height is driven by a transform.scale.y on this path, not by
    // redrawing it — but a non-uniform scale (X stays 1, Y shrinks to
    // `scale`) squishes a fixed-radius cap into an ellipse for any scale
    // below 1.0, which is most of the time. To keep the caps looking like
    // true semicircles at every height, pre-stretch yRadius by 1/scale here
    // so the transform squishes it back down to exactly barWidth/2.
    private func barPath(scale: CGFloat) -> CGPath {
        let targetRadius = Self.barWidth / 2
        let compensatedYRadius = min(Self.totalHeight / 2, targetRadius / max(scale, 0.05))
        return NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.totalHeight),
                            xRadius: targetRadius,
                            yRadius: compensatedYRadius).cgPath
    }
    
    private func startAnimating() {
        guard animationTimer == nil else { return }
        if #available(macOS 14.2, *) {
            // Rest at dots until the live meter actually has signal — no more
            // random bounce filler while CoreAudio's tap is still spinning up
            // (process lookup, aggregate device creation, IOProc registration)
            // or the track hasn't produced audible sound yet.
            resetBars()
            meterCancellable = LiveAudioMeter.shared.$amplitudes
                .receive(on: DispatchQueue.main)
                .throttle(for: .milliseconds(70), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] amplitudes in
                    guard let self, self.currentIsPlaying else { return }
                    let hasSignal = amplitudes.contains { $0 > 0.01 }
                    if hasSignal {
                        self.updateBars(amplitudes: amplitudes)
                    } else {
                        self.resetBars()
                    }
                }
            // Defensive re-check in case the publisher stalls without emitting —
            // keeps bars pinned at dots instead of frozen mid-pose.
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
                guard let self else { return }
                let hasSignal = LiveAudioMeter.shared.amplitudes.contains { $0 > 0.01 }
                if hasSignal { return }
                self.resetBars()
            }
        } else {
            // No live meter available pre-14.2 — rest at dots, same as everywhere else
            resetBars()
        }
    }
    
    private func stopAnimating() {
            meterCancellable?.cancel()
            meterCancellable = nil
            animationTimer?.invalidate()
            animationTimer = nil
            resetBars()
        }
    
    // Only called with real signal now — the no-signal case rests at dots via
    // resetBars() instead (see startAnimating).
    private func updateBars(amplitudes: [Float]) {
            for (i, barLayer) in barLayers.enumerated() {
                guard i < amplitudes.count else { continue }
                let currentScale = barScales[i]
                let dotScale: CGFloat = 2.0 / Self.totalHeight
                let clamped = CGFloat(min(1.0, amplitudes[i]))
                let targetScale = max(dotScale, clamped)
                barScales[i] = targetScale
                // Snap path instantly — spring morphing causes bezier warping.
                // Rebuilding it for the new target keeps the cap radius correct
                // once the spring settles (see barPath's compensation comment).
                barLayer.path = barPath(scale: targetScale)
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
            }
        }
    
    private func resetBars() {
        let dotScale: CGFloat = 2.0 / Self.totalHeight
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.path = barPath(scale: dotScale)
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

/// Blurred, dimmed album art masked to the shape of the running waveform bars.
/// Used both in the closed-notch live activity and the open notch's music view —
/// pulled out so the two don't drift out of sync the way their frame sizes did.
struct AlbumArtWaveformMask: View {
    let albumArt: NSImage
    @Binding var isPlaying: Bool

    private static let artSize = CGSize(width: 36, height: 22)

    var body: some View {
        ZStack {
            Image(nsImage: albumArt)
                .resizable()
                .scaledToFill()
                .frame(width: Self.artSize.width, height: Self.artSize.height)
                .blur(radius: 4)
                .saturation(1.1)
                .brightness(0.05)
            Color.white.opacity(0.03)
                .frame(width: Self.artSize.width, height: Self.artSize.height)
        }
        .mask {
            AudioSpectrumView(isPlaying: $isPlaying)
                .frame(width: AudioSpectrum.recommendedFrameSize.width, height: AudioSpectrum.recommendedFrameSize.height)
        }
        .frame(width: AudioSpectrum.recommendedFrameSize.width, height: AudioSpectrum.recommendedFrameSize.height)
        .clipped()
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
