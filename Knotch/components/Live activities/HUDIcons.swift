//
//  HUDIcons.swift
//  Knotch
//

import SwiftUI

// MARK: - Speaker animation state

@Observable
final class SpeakerAnimationState {
    var slashScale: CGFloat = 1.0
    var wave1Scale: CGFloat = 0.0
    var wave2Scale: CGFloat = 0.0
    var wave3Scale: CGFloat = 0.0

    private var isMuted:  Bool = true
    private var hasWave1: Bool = false
    private var hasWave2: Bool = false
    private var hasWave3: Bool = false

    private let spring = Animation.spring(response: 0.3, dampingFraction: 0.72)
    private let w1: CGFloat = 0.01
    private let w2: CGFloat = 0.34
    private let w3: CGFloat = 0.67

    func setInitial(_ value: CGFloat) {
        isMuted  = value == 0
        hasWave1 = value > w1
        hasWave2 = value > w2
        hasWave3 = value > w3
        slashScale = isMuted  ? 1 : 0
        wave1Scale = hasWave1 ? 1 : 0
        wave2Scale = hasWave2 ? 1 : 0
        wave3Scale = hasWave3 ? 1 : 0
    }

    func update(_ value: CGFloat) {
        let newMuted  = value == 0
        let newWave1  = value > w1
        let newWave2  = value > w2
        let newWave3  = value > w3

        if newMuted != isMuted {
            isMuted = newMuted
            withAnimation(spring) { slashScale = isMuted  ? 1 : 0 }
        }
        if newWave1 != hasWave1 {
            hasWave1 = newWave1
            withAnimation(spring) { wave1Scale = hasWave1 ? 1 : 0 }
        }
        if newWave2 != hasWave2 {
            hasWave2 = newWave2
            withAnimation(spring) { wave2Scale = hasWave2 ? 1 : 0 }
        }
        if newWave3 != hasWave3 {
            hasWave3 = newWave3
            withAnimation(spring) { wave3Scale = hasWave3 ? 1 : 0 }
        }
    }
}

// MARK: - Speaker Icon

struct SpeakerWaveIcon: View {
    let value: CGFloat
    let size: CGFloat

    @State private var state = SpeakerAnimationState()

    var body: some View {
        let h = size
        let w = size * 1.4

        Canvas { ctx, canvasSize in
            let ch = canvasSize.height
            let cw = canvasSize.width

            // ── Cone geometry ──────────────────────────────────────────
            // Measured from reference screenshots, normalised to ch (icon height).
            // The cone has three zones:
            //   Upper wedge:  y 0.00-0.26 — diagonal, narrows to rounded tip at top
            //   Sharp step:   at y≈0.28, body suddenly widens to left edge ≈ 0
            //   Wide body:    y 0.28-0.74 — near-rectangular, left≈0, right=0.698ch
            //   Sharp step:   at y≈0.74, body suddenly narrows
            //   Lower wedge:  y 0.74-1.00 — mirror of upper wedge

            let coneRight = 0.698 * ch   // flat right wall
            let tipX      = 0.610 * ch   // x-position of the top/bottom tip centre

            var cone = Path()

            // Start at top tip (rounded narrow point)
            cone.move(to: CGPoint(x: tipX - 0.005 * ch, y: 0.00 * ch))

            // Upper wedge: tip curves down-left to the step point
            // Left edge goes from tipX at y=0 to 0.295ch at y=0.26ch
            cone.addLine(to: CGPoint(x: 0.295 * ch, y: 0.26 * ch))

            // Sharp step left: jump to wide body left edge
            cone.addLine(to: CGPoint(x: 0.020 * ch, y: 0.29 * ch))

            // Wide rectangular body left wall (straight down)
            cone.addLine(to: CGPoint(x: 0.000 * ch, y: 0.71 * ch))

            // Sharp step right at bottom of body
            cone.addLine(to: CGPoint(x: 0.096 * ch, y: 0.74 * ch))

            // Lower wedge: narrows back to tip
            cone.addLine(to: CGPoint(x: tipX - 0.005 * ch, y: 1.00 * ch))

            // Close across the flat right wall back up to the top
            // Right wall: straight from bottom-right to top-right
            cone.addLine(to: CGPoint(x: coneRight, y: 1.00 * ch))
            cone.addLine(to: CGPoint(x: coneRight, y: 0.00 * ch))

            cone.closeSubpath()
            ctx.fill(cone, with: .foreground)

            // ── Slash ──────────────────────────────────────────────────
            let s = state.slashScale
            if s > 0 {
                // Slash: from upper-left area to lower-right area
                // Measured: approx (0.27cw, 0.10ch) → (0.95cw, 0.90ch)
                let slashStart = CGPoint(x: cw * 0.27, y: ch * 0.10)
                let slashEnd   = CGPoint(x: cw * 0.95, y: ch * 0.90)
                let mid = CGPoint(
                    x: (slashStart.x + slashEnd.x) / 2,
                    y: (slashStart.y + slashEnd.y) / 2
                )
                var slash = Path()
                slash.move(to: CGPoint(
                    x: mid.x + (slashStart.x - mid.x) * s,
                    y: mid.y + (slashStart.y - mid.y) * s
                ))
                slash.addLine(to: CGPoint(
                    x: mid.x + (slashEnd.x - mid.x) * s,
                    y: mid.y + (slashEnd.y - mid.y) * s
                ))
                ctx.stroke(slash, with: .foreground,
                           style: StrokeStyle(lineWidth: ch * 0.105, lineCap: .round))
            }
        }
        .frame(width: w, height: h)
        .overlay(alignment: .topLeading) {
            GeometryReader { geo in
                let ch  = geo.size.height
                // Arc origin at cone right wall, vertical centre
                let origin  = CGPoint(x: 0.698 * ch, y: 0.50 * ch)
                // Stroke width and arc angle from reference measurements
                let strokeW = ch * 0.125
                let halfDeg = 54.0

                ZStack {
                    // Wave radii: 0.30H, 0.57H, 0.84H (equal spacing, measured)
                    WaveArc(origin: origin, radius: ch * 0.30,
                            strokeWidth: strokeW, halfAngleDeg: halfDeg,
                            progress: state.wave1Scale)

                    WaveArc(origin: origin, radius: ch * 0.57,
                            strokeWidth: strokeW, halfAngleDeg: halfDeg,
                            progress: state.wave2Scale)

                    WaveArc(origin: origin, radius: ch * 0.84,
                            strokeWidth: strokeW, halfAngleDeg: halfDeg,
                            progress: state.wave3Scale)
                }
            }
        }
        .onChange(of: value) { _, newVal in state.update(newVal) }
        .onAppear { state.setInitial(value) }
    }
}

// MARK: - Wave Arc

private struct WaveArc: View {
    let origin: CGPoint
    let radius: CGFloat
    let strokeWidth: CGFloat
    let halfAngleDeg: Double
    let progress: CGFloat

    var body: some View {
        let currentHalf = halfAngleDeg * Double(progress)
        Canvas { ctx, _ in
            guard currentHalf > 0.5 else { return }
            var arc = Path()
            arc.addArc(center: origin,
                       radius: radius,
                       startAngle: .degrees(-currentHalf),
                       endAngle:   .degrees(currentHalf),
                       clockwise: false)
            ctx.stroke(arc, with: .foreground,
                       style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
        }
        .opacity(Double(min(1, progress * 2)))
    }
}

// MARK: - Sun animation state

@Observable
final class SunAnimationState {
    var raysScale: CGFloat = 0.0
    private var hasRays: Bool = false
    private let spring = Animation.spring(response: 0.3, dampingFraction: 0.72)
    private let threshold: CGFloat = 0.01

    func setInitial(_ value: CGFloat) {
        hasRays   = value > threshold
        raysScale = hasRays ? 1 : 0
    }

    func update(_ value: CGFloat) {
        let newHasRays = value > threshold
        guard newHasRays != hasRays else { return }
        hasRays = newHasRays
        withAnimation(spring) { raysScale = hasRays ? 1 : 0 }
    }
}

// MARK: - Sun Rays Icon

struct SunRaysIcon: View {
    let value: CGFloat
    let size: CGFloat

    @State private var state = SunAnimationState()
    private let rayCount = 8

    var body: some View {
        Canvas { ctx, canvasSize in
            let cx = canvasSize.width  / 2
            let cy = canvasSize.height / 2
            let h  = canvasSize.height

            let circleRadius = h * 0.22
            let rayStart     = circleRadius + h * 0.06
            let rayLen       = h * 0.22 * state.raysScale
            let strokeW      = h * 0.10

            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - circleRadius, y: cy - circleRadius,
                                       width: circleRadius * 2, height: circleRadius * 2)),
                with: .foreground
            )
            guard rayLen > 0 else { return }
            for i in 0..<rayCount {
                let angle = Double(i) * (2 * .pi / Double(rayCount))
                var ray = Path()
                ray.move(to: CGPoint(x: cx + cos(angle) * rayStart,
                                     y: cy + sin(angle) * rayStart))
                ray.addLine(to: CGPoint(x: cx + cos(angle) * (rayStart + rayLen),
                                        y: cy + sin(angle) * (rayStart + rayLen)))
                ctx.stroke(ray, with: .foreground,
                           style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .onChange(of: value) { _, newVal in state.update(newVal) }
        .onAppear { state.setInitial(value) }
    }
}
