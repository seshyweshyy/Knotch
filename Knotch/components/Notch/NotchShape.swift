//
//  NotchShape.swift
//  Knotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
    }

    // Restored after root-causing the open-animation drift to
    // NSGlassEffectView's own stale backdrop capture (fixed via
    // KnotchSkyLightWindow's .knotchWillOpen -> refreshGlassBackdrop()),
    // rather than to this interpolating. Without Animatable, the radius
    // snapped instantly on every notchState change — harmless when closing
    // to an empty notch, but visibly wrong when closing to the live-activity
    // bar (a real in-between size): the panel was still mid-shrink via
    // .frame()'s own animation while its corners jumped straight to the
    // fully-closed radius, ahead of the shape actually getting that small.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            AnimatablePair(topCornerRadius, bottomCornerRadius)
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Clamp to what this specific rect can actually fit. The frame this
        // shape clips animates its own width/height independently of these
        // radii (see above), so early in an open transition the rect can
        // briefly be smaller than the target radii assume — unclamped, that
        // produces overlapping/degenerate geometry (the shape visibly
        // squishing/reshaping oddly right as an open begins). Deriving the
        // clamp from this same rect every frame guarantees the shape is
        // never degenerate, and lets the radius grow in proportion as the
        // rect grows with no separate interpolation needed.
        let maxCombined = max(0, rect.width / 2)
        let top = min(max(0, topCornerRadius), rect.height, maxCombined)
        let bottom = min(max(0, bottomCornerRadius), rect.height, max(0, maxCombined - top))

        var path = Path()

        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + top,
                y: rect.minY + top
            ),
            control: CGPoint(
                x: rect.minX + top,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX + top,
                y: rect.maxY - bottom
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + top + bottom,
                y: rect.maxY
            ),
            control: CGPoint(
                x: rect.minX + top,
                y: rect.maxY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - top - bottom,
                y: rect.maxY
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX - top,
                y: rect.maxY - bottom
            ),
            control: CGPoint(
                x: rect.maxX - top,
                y: rect.maxY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - top,
                y: rect.minY + top
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            ),
            control: CGPoint(
                x: rect.maxX - top,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        return path
    }
}

#Preview {
    NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        .frame(width: 200, height: 32)
        .padding(10)
}
