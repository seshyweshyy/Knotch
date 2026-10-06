//
//  MultiActivityViews.swift
//  Knotch
//
//  The pieces of the closed notch's multi-activity presentation — when both
//  the music and timer live activities are showing, the compact pill splits
//  into an attached minimal shape (one glyph beside the camera gap) and a
//  detached minimal bubble, like the iOS Dynamic Island's two-activity state.
//

import Defaults
import SwiftUI

/// Width of the wing a minimal attached activity adds beside the camera gap.
func minimalWingWidth(effectiveClosedNotchHeight: CGFloat) -> CGFloat {
    effectiveClosedNotchHeight + 4
}

/// The closed pill's semi-liquid-glass fade: opaque black at the top, easing
/// to clear glass at the bottom. Shared by the notch's own background and the
/// detached bubble's, so the two read as one material.
let closedGlassGradient = LinearGradient(
    stops: [
        .init(color: .black, location: 0),
        .init(color: .black, location: 0.7),
        .init(color: .black.opacity(0.6), location: 0.8),
        .init(color: .clear, location: 0.9),
        .init(color: .clear, location: 1),
    ],
    startPoint: .top,
    endPoint: .bottom
)

/// The timer's countdown ring — drains as the timer counts down, with a dial
/// tick riding the drained arc's leading edge. Line width and tick scale with
/// `size` (they're 2pt / 2x5pt at the compact pill's 16pt).
///
/// Drives itself from a TimelineView (reading the clock each frame) instead of
/// relying on whoever owns it re-rendering once a second: a ring inside the
/// detached bubble sits under a view that doesn't reliably re-render on the
/// timer's tick, which left it frozen. Continuous, so the arc also drains
/// smoothly rather than stepping each second. Paused timers stop the clock.
struct TimerProgressRing: View {
    let timer: KnotchTimer
    let color: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: timer.isPaused)) { context in
            ring(progress: max(0, min(1, timer.remaining(at: context.date) / timer.duration)))
        }
        .frame(width: size, height: size)
    }

    private func ring(progress: Double) -> some View {
        let lineWidth = size / 8

        return ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Capsule()
                .fill(color)
                .frame(width: lineWidth, height: size * 5 / 16)
                .offset(y: -size * 3 / 16)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(progress * 360))
        }
    }
}

/// One activity's minimal glyph — album art for music, the countdown ring for
/// the timer. Used both in the attached shape's wing and inside the bubble.
/// Each keeps exactly the size it has in its compact pill (MusicLiveActivity's
/// resting art size, TimerCompactPill's 16pt ring), so going minimal doesn't
/// resize the item.
struct MinimalActivityGlyph: View {
    let family: ClosedRowFamily
    let closedHeight: CGFloat

    var body: some View {
        switch family {
        case .music:
            MinimalMusicArt(size: max(0, closedHeight - 12))
        case .timer:
            MinimalTimerGlyph(size: 16)
        default:
            EmptyView()
        }
    }

    /// The gap between the shape's leading edge and the glyph in the compact
    /// pill (MusicLiveActivity's art padding, TimerCompactPill's horizontal
    /// padding) — the attached wing keeps it too.
    static func leadingInset(for family: ClosedRowFamily, isIsland: Bool) -> CGFloat {
        family == .music ? (isIsland ? 1 : 5) : 4
    }
}

private struct MinimalMusicArt: View {
    @ObservedObject var musicManager = MusicManager.shared
    let size: CGFloat

    // The same state MusicLiveActivity's own art keeps for its track-change
    // flip, and the same effects on top: a 3D flip with blur/brightness when
    // the track changes, a dimmed + shrunk look while paused.
    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var rotationDegrees: Double = 0
    @State private var flipBlur: CGFloat = 0
    @State private var flipBrightness: Double = 0

    // The placeholder icon has no playing/paused state of its own to dim.
    private var showsPausedLook: Bool {
        !musicManager.isPlaying && displayedArt !== noArtworkPlaceholderImage
    }

    var body: some View {
        Image(nsImage: displayedArt)
            .resizable()
            // Wide artwork (e.g. YouTube thumbnails) keeps its aspect ratio,
            // letterboxed — same as the compact pill's art.
            .scaledToFit()
            .clipShape(
                RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed / 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed / 2)
                    .foregroundColor(.black)
                    .opacity(showsPausedLook ? 0.3 : 0)
                    .allowsHitTesting(false)
            )
            .frame(width: size, height: size)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed))
            .rotation3DEffect(
                .degrees(rotationDegrees),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.4
            )
            .blur(radius: flipBlur)
            .brightness(flipBrightness)
            .onChange(of: musicManager.artFlipSignal) { _, signal in
                let dir: Double = signal.direction == .forward ? 1 : -1

                withAnimation(.easeIn(duration: 0.22)) {
                    rotationDegrees = dir * 90
                    flipBlur = 4
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    displayedArt = signal.art
                    rotationDegrees = dir * -90
                    flipBrightness = 0.6
                    withAnimation(.easeOut(duration: 0.22)) {
                        rotationDegrees = 0
                        flipBlur = 0
                        flipBrightness = 0
                    }
                }
            }
            .scaleEffect(showsPausedLook ? 0.90 : 1)
            .animation(.smooth(duration: 0.35), value: showsPausedLook)
    }
}

private struct MinimalTimerGlyph: View {
    @ObservedObject var timerManager = TimerManager.shared
    @Default(.notchAppearanceStyle) var notchAppearanceStyle
    let size: CGFloat

    var body: some View {
        if let timer = timerManager.soonestActiveTimer {
            TimerProgressRing(
                timer: timer,
                color: notchAppearanceStyle == .fullLiquidGlass ? .white : .orange,
                size: size
            )
        }
    }
}

/// The detached minimal bubble — a small circle beside the attached shape,
/// with the same material (solid black / semi / full liquid glass) and
/// contrast outline as the notch itself.
///
/// `progress` runs 0...1: at 0 the bubble is tucked back into the attached
/// shape (invisible), at 1 it sits fully split out. The slide, the stretch
/// mid-way and the fade all derive from it, so the split and the merge are
/// the same motion in opposite directions. The parent lays the bubble out at
/// its final (`progress == 1`) position; `slideDistance` is how far back
/// toward the attached shape it starts.
struct DetachedActivityBubble: View {
    @Default(.notchAppearanceStyle) var notchAppearanceStyle
    @Default(.contrastOutline) var contrastOutline
    @Default(.alwaysShowContrastOutline) var alwaysShowContrastOutline
    @State private var outlineEdges: Set<KnotchContrastOutline.Edge> = []

    let family: ClosedRowFamily
    let diameter: CGFloat
    // The closed notch's height — what the glyphs size themselves from (the
    // bubble's own diameter can differ from it).
    let closedHeight: CGFloat
    // The space between the attached shape's edge and the bubble at rest.
    let gap: CGFloat
    // The attached shape's trailing-end corner radii (top / bottom): the
    // island's capsule end, or the notch's square top and rounded bottom.
    // The bubble is masked by that silhouette so it emerges from behind it.
    let endTopRadius: CGFloat
    let endBottomRadius: CGFloat
    let slideDistance: CGFloat
    let progress: CGFloat

    // Deliberately slower than the panel's own open/close springs (tuned for
    // the metaball neck, currently disabled: it only shows while the bubble is
    // still on its way out, and a quick spring crosses that window in a couple
    // of frames). No bounce: an overshoot would bring the bubble back through
    // the range where the neck is drawn, re-growing it right after it pinched
    // off.
    private static let splitAnimation = Animation.spring(duration: 0.42, bounce: 0)
    // A timed curve, not a spring: a critically damped spring approaches 0
    // asymptotically and takes a long time to actually arrive, which left the
    // bubble sitting there (as an empty circle) well after it had merged.
    private static let mergeAnimation = Animation.easeInOut(duration: 0.3)

    var body: some View {
        // The bubble's own d x d frame with the bubble drawn over it; everything
        // animates off `progress`.
        Color.clear
            .frame(width: diameter, height: diameter)
            // METABALL NECK — disabled for now; see the commented-out `neck` and
            // `MetaballNeck` below (and the metaball-neck memory note) to bring it back:
            // .background(alignment: .topLeading) {
            //     neck
            //         // Give the bridge real drawing bounds all the way back to
            //         // the attached shape. Rendering most of an animated path
            //         // at negative x outside a d x d background produced the
            //         // every-other-frame disappearance visible in the capture.
            //         .frame(width: diameter + slideDistance, height: diameter)
            //         .offset(x: -slideDistance)
            //         .allowsHitTesting(false)
            // }
            .overlay { bubbleBody }
            // Emerges from BEHIND the attached shape: whatever part of the
            // bubble is still inside the shape's silhouette is masked away.
            // (The bubble is drawn above the notch — it has to be, or the
            // notch's own hover area, which reaches past its edge, would
            // swallow hovers and taps on the bubble — so the shape is cut out
            // of it instead of being layered over it.)
            .mask { behindAttachedShapeMask }
            .allowsHitTesting(progress > 0.5)
            .animation(progress > 0.5 ? Self.splitAnimation : Self.mergeAnimation, value: progress)
    }

    // Everything except the attached shape's silhouette, in the bubble's own
    // frame (its resting left edge is x = 0, the shape's trailing edge sits
    // `gap` to its left). The silhouette uses the shape's real trailing-end
    // corner radii — a capsule end on the island, a flat wall with a rounded
    // bottom on the notch — so the bubble slides out from behind the curve
    // instead of a straight vertical cut.
    private var behindAttachedShapeMask: some View {
        let silhouetteWidth: CGFloat = 400
        return ZStack {
            Color.white.frame(width: 600, height: 300)
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: endBottomRadius,
                topTrailingRadius: endTopRadius,
                style: .circular
            )
            .fill(Color.black)
            .frame(width: silhouetteWidth, height: closedHeight)
            // Trailing edge at x = -gap, vertically centered on the bubble.
            .offset(x: -gap - silhouetteWidth / 2 - diameter / 2)
            .blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    /* DISABLED — the gooey neck's fill. Re-enable together with the `.background`
       in `body` and the `MetaballNeck` shape at the bottom of this file.

    // The liquid bridge between the attached shape and the bubble while they
    // pull apart (or merge), filled with the notch's own material: solid
    // black exactly; for the glass styles the same black gradient (and tint)
    // the notch's background puts over its glass, so the bridge fades out
    // toward the bottom like the pill does. It only covers what's outside
    // the attached shape (see MetaballNeck), so it never doubles up the
    // pill's own tint where they overlap.
    @ViewBuilder
    private var neck: some View {
        let shape = MetaballNeck(
            progress: progress,
            closedHeight: closedHeight,
            diameter: diameter,
            gap: gap,
            slideDistance: slideDistance,
            endTopRadius: endTopRadius,
            endBottomRadius: endBottomRadius
        )
        if #available(macOS 26, *), notchAppearanceStyle == .semiLiquidGlass {
            ZStack {
                shape.fill(closedGlassGradient)
                shape.fill(Color.black.opacity(0.25))
            }
        } else if #available(macOS 26, *), notchAppearanceStyle == .fullLiquidGlass {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.25))
            }
        } else {
            shape.fill(Color.black)
        }
    }
    */

    private var bubbleBody: some View {
        ZStack {
            background
            MinimalActivityGlyph(family: family, closedHeight: closedHeight)
                .modifier(BubbleContentReveal(progress: progress))
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .knotchContrastOutline(
            isEnabled: KnotchContrastOutline.isActive(
                enabled: contrastOutline,
                style: notchAppearanceStyle
            ),
            isActivityActive: true,
            visibleEdges: $outlineEdges,
            shape: notchOuterShape(
                topCornerRadius: diameter / 2,
                bottomCornerRadius: diameter / 2,
                isIsland: true
            ),
            color: .white,
            opacity: KnotchContrastOutline.outlineOpacity,
            forceVisible: alwaysShowContrastOutline
        )
        // Keep every transform on the same interpolated progress that the
        // neck consumes. Computing sin(progress) directly in this View only
        // gives SwiftUI the two endpoint values (both are 1 for stretch), so
        // the rendered bubble otherwise does not follow the geometry used by
        // MetaballNeck between those endpoints.
        .modifier(BubbleMotionEffect(progress: progress, slideDistance: slideDistance))
        // No fade on the shape itself — it slides back into the attached
        // shape (black on black); only its content blurs away (see
        // BubbleContentReveal).
        .modifier(BubbleHiddenWhenMerged(progress: progress))
    }

    @ViewBuilder
    private var background: some View {
        if #available(macOS 26, *), notchAppearanceStyle != .solidBlack {
            ZStack {
                KnotchLiquidGlass(shape: .roundedRect(cornerRadius: diameter / 2))
                if notchAppearanceStyle == .semiLiquidGlass {
                    Color.black.mask { closedGlassGradient }
                }
                Color.black.opacity(0.25)
            }
        } else {
            Color.black
        }
    }
}

/// The bubble's split/merge motion, shared by the bubble itself and the neck
/// drawn behind it so the two can't drift apart.
private enum BubbleMotion {
    static func clamped(_ progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1)
    }

    /// Stretched along the slide axis mid-way — the bubble pulling away.
    static func stretch(_ progress: CGFloat) -> CGFloat {
        1 + 0.2 * sin(clamped(progress) * .pi)
    }

    /// Grows from 0.6x to full size as it splits out.
    static func scale(_ progress: CGFloat) -> CGFloat {
        0.6 + 0.4 * clamped(progress)
    }

    static func crossAxisScale(_ progress: CGFloat) -> CGFloat {
        1 - (stretch(progress) - 1) * 0.3
    }

    /// The leading edge after the same ordered transforms used by
    /// BubbleMotionEffect: leading-anchored stretch, then center-anchored
    /// uniform scale, then translation.
    static func leftEdge(
        _ progress: CGFloat,
        diameter: CGFloat,
        slideDistance: CGFloat
    ) -> CGFloat {
        let p = clamped(progress)
        return -(1 - p) * slideDistance + diameter / 2 * (1 - scale(p))
    }
}

/// Animates the motion input itself, rather than independently interpolating
/// the already-derived scale/offset endpoints. This is what lets the bubble's
/// non-linear mid-flight stretch exactly match MetaballNeck's geometry.
private struct BubbleMotionEffect: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    let slideDistance: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = BubbleMotion.clamped(progress)
        content
            .scaleEffect(
                x: BubbleMotion.stretch(p),
                y: BubbleMotion.crossAxisScale(p),
                anchor: .leading
            )
            .scaleEffect(BubbleMotion.scale(p))
            .offset(x: -(1 - p) * slideDistance)
    }
}

/* DISABLED — the metaball neck. It draws a liquid bridge between the attached
   shape and the detached bubble while the bubble pulls out (see the
   metaball-neck note in the project memory for how it works and every pitfall
   hit while building it). To bring it back: uncomment this shape, the `neck`
   view above and the `.background` in DetachedActivityBubble.body. The bubble's
   `gap`, `endTopRadius` and `endBottomRadius` parameters (and BubbleMotion's
   `leftEdge`) exist only for it.

/// The liquid bridge ("metaball neck") between the attached shape and the
/// bubble — the shape itself stretching out into a waist and pinching off.
/// In the bubble's own d x d frame: the bubble's final left edge is x = 0 and
/// the attached shape's trailing edge sits `gap` to its left.
///
/// Its root follows the attached shape's real trailing boundary, with a tiny
/// overlap to prevent an antialiasing seam; from there each side curves in to
/// a waist and out to meet the bubble's current ellipse tangentially.
/// It thins with progress (to nothing as the bubble arrives) and with how far
/// the bubble has emerged from the shape (so it grows in as the bubble first
/// pokes out).
private struct MetaballNeck: Shape {
    var progress: CGFloat
    let closedHeight: CGFloat
    let diameter: CGFloat
    let gap: CGFloat
    let slideDistance: CGFloat
    let endTopRadius: CGFloat
    let endBottomRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = BubbleMotion.clamped(progress)
        let stretch = BubbleMotion.stretch(p)
        let scale = BubbleMotion.scale(p)

        // The bubble as it currently is — same transforms the bubble applies.
        let rBx = diameter * stretch * scale / 2
        let rBy = diameter * BubbleMotion.crossAxisScale(p) * scale / 2
        // The expanded backing canvas ends at the bubble's own trailing edge;
        // recover its resting leading edge so the geometry stays expressed in
        // the same bubble-local coordinate system as BubbleMotionEffect.
        let bubbleRestingLeftX = rect.maxX - diameter
        let centerY = rect.minY + diameter / 2
        let edgeX = bubbleRestingLeftX - gap
        let leftEdge = bubbleRestingLeftX + BubbleMotion.leftEdge(
            p,
            diameter: diameter,
            slideDistance: slideDistance
        )
        let cBx = leftEdge + rBx

        // No neck until the bubble actually pokes out of the shape.
        let poke = cBx + rBx - edgeX
        guard poke > 0.5 else { return Path() }
        // Driven by how far the bubble's leading surface is from the shape's
        // edge (not by progress): full thickness while they overlap, thinning
        // as the strand stretches across the gap, snapped as the bubble
        // reaches its resting distance. Progress alone would have
        // finished the neck while the bubble was still inside the shape, i.e.
        // before there was any gap for it to cross — leaving nothing to see.
        let separation = (cBx - rBx) - edgeX
        // Full while the bubble is still inside the shape (out of sight),
        // then thinning steadily from the moment it clears the edge — never
        // holding at full thickness while the strand lengthens, which read as
        // the neck swelling just before it broke.
        let u = min(1, max(0, separation / gap))
        // Keep more visual weight through the tiny 4/7pt gap. The previous
        // 1.6 exponent made the bridge lose almost three quarters of its
        // thickness by halfway across the notch gap, so only the final wisp
        // was perceptible. This eased falloff stays broad long enough to read
        // as goo, but still reaches exactly zero at the unchanged resting gap.
        // Smooth the remaining distance before applying the visual boost.
        // `pow(1 - u, 0.72)` had an increasingly steep slope near zero: it
        // kept a visible 2px strand until the last moment, then dropped it in
        // one frame. Smoothstep has a zero slope at both ends; the exponent
        // retains the same ~61% midpoint weight without the terminal snap.
        let remaining = 1 - u
        let smoothRemaining = remaining * remaining * (3 - 2 * remaining)
        let strength = pow(smoothRemaining, 0.72) * min(1, poke / 8)
        // Only discard geometry far below subpixel visibility. Let normal
        // antialiasing fade the final strand instead of imposing a visible
        // cutoff while it is still a couple of pixels thick.
        guard strength > 0.0005 else { return Path() }

        let thickness = min(1, strength * 1.4)
        // The attached shape does not transform. Instead, the bridge itself
        // grows a rounded source lobe out of its edge, matching the way iOS's
        // main island appears to participate in the goo without stretching
        // the island's actual frame or mask.
        let halfSource = closedHeight * 0.32 * pow(strength, 0.62)
        // Use a fixed physical maximum rather than a fraction of the bubble's
        // still-growing radius. `strength` is monotone after clearance, but
        // `rB * strength` was not: the increasing rB won for a few frames and
        // made the contact visibly swell immediately before pinch-off.
        let halfContact = min(rBy * 0.9, diameter * 0.34 * thickness)
        let psi = asin(min(1, halfContact / rBy))
        let surfaceContactX = cBx - rBx * cos(psi)
        // A shrinking contact constrained to the ellipse slides toward its
        // leftmost point. Near pinch-off that made the bubble-side lobe move
        // back outward and read as regrowth, even though its height was still
        // decreasing. Pull the endpoint beneath the bubble instead. The
        // bubble is composited over the neck, so this hidden inset makes the
        // visible strand retract into the bubble while remaining flush to its
        // edge, without changing the bubble's own shape or motion.
        let bubbleSelfPull = diameter * 0.14 * pow(1 - thickness, 2)
        let contactX = surfaceContactX + bubbleSelfPull

        // Tangents at the corresponding points on the bubble's current
        // ellipse, normalized before they are used as Bezier handles. The
        // actual endpoints can sit just beneath the bubble during self-pull.
        let tangentLength = hypot(rBx * sin(psi), rBy * cos(psi))
        guard tangentLength > 0 else { return Path() }
        let tangentUpper = CGPoint(
            x: rBx * sin(psi) / tangentLength,
            y: -rBy * cos(psi) / tangentLength
        )
        let tangentLower = CGPoint(
            x: rBx * sin(psi) / tangentLength,
            y: rBy * cos(psi) / tangentLength
        )

        let rootTopY = centerY - halfSource
        let rootBottomY = centerY + halfSource
        // Start directly on the attached silhouette instead of drawing a
        // large path through it and boolean-subtracting that silhouette every
        // frame. The tiny overlap keeps antialiasing from opening a seam.
        let overlap: CGFloat = 0.75
        let rootTop = CGPoint(
            x: attachedBoundaryX(at: rootTopY, centerY: centerY, edgeX: edgeX) - overlap,
            y: rootTopY
        )
        let rootBottom = CGPoint(
            x: attachedBoundaryX(at: rootBottomY, centerY: centerY, edgeX: edgeX) - overlap,
            y: rootBottomY
        )
        let contactTop = CGPoint(x: contactX, y: centerY - halfContact)
        let contactBottom = CGPoint(x: contactX, y: centerY + halfContact)

        let sourceEdgeX = max(rootTop.x, rootBottom.x)
        let bridgeLength = contactX - sourceEdgeX
        guard bridgeLength > 0 else { return Path() }

        // Split each side at an explicit waist. A single cubic between the
        // two bodies reads as one object dragging a strand; the narrow middle
        // with wider attachments on both ends gives both the main shape and
        // bubble their own liquid pull/lobe while leaving both base shapes
        // untouched.
        let waistX = sourceEdgeX + bridgeLength * 0.46
        let halfWaist = min(halfSource, halfContact) * 0.44
        let waistTop = CGPoint(x: waistX, y: centerY - halfWaist)
        let waistBottom = CGPoint(x: waistX, y: centerY + halfWaist)

        let topSourceLength = waistX - rootTop.x
        let bottomSourceLength = waistX - rootBottom.x
        let bubbleLength = contactX - waistX
        guard topSourceLength > 0, bottomSourceLength > 0, bubbleLength > 0 else {
            return Path()
        }

        var path = Path()
        path.move(to: rootTop)
        path.addCurve(
            to: waistTop,
            control1: CGPoint(x: rootTop.x + topSourceLength * 0.58, y: rootTop.y),
            control2: CGPoint(x: waistTop.x - topSourceLength * 0.32, y: waistTop.y)
        )
        path.addCurve(
            to: contactTop,
            control1: CGPoint(x: waistTop.x + bubbleLength * 0.32, y: waistTop.y),
            control2: CGPoint(
                x: contactTop.x - bubbleLength * 0.58 * tangentUpper.x,
                y: contactTop.y - bubbleLength * 0.58 * tangentUpper.y
            )
        )
        path.addLine(to: contactBottom)
        path.addCurve(
            to: waistBottom,
            control1: CGPoint(
                x: contactBottom.x - bubbleLength * 0.58 * tangentLower.x,
                y: contactBottom.y - bubbleLength * 0.58 * tangentLower.y
            ),
            control2: CGPoint(x: waistBottom.x + bubbleLength * 0.32, y: waistBottom.y)
        )
        path.addCurve(
            to: rootBottom,
            control1: CGPoint(x: waistBottom.x - bottomSourceLength * 0.32, y: waistBottom.y),
            control2: CGPoint(x: rootBottom.x + bottomSourceLength * 0.58, y: rootBottom.y)
        )
        path.closeSubpath()
        return path
    }

    /// Trailing boundary of the same uneven-rounded silhouette previously
    /// used for subtraction. The physical-notch top radius is zero (the wall
    /// is flat there); its bottom corner and both capsule corners are arcs.
    private func attachedBoundaryX(at y: CGFloat, centerY: CGFloat, edgeX: CGFloat) -> CGFloat {
        let top = centerY - closedHeight / 2
        let bottom = centerY + closedHeight / 2

        if endTopRadius > 0, y < top + endTopRadius {
            let cy = top + endTopRadius
            let dy = y - cy
            return edgeX - endTopRadius
                + sqrt(max(0, endTopRadius * endTopRadius - dy * dy))
        }
        if endBottomRadius > 0, y > bottom - endBottomRadius {
            let cy = bottom - endBottomRadius
            let dy = y - cy
            return edgeX - endBottomRadius
                + sqrt(max(0, endBottomRadius * endBottomRadius - dy * dy))
        }
        return edgeX
    }
}
*/

/// Fades the bubble's *content* in and out the way the closed row's content
/// does when a live activity collapses to idle — blur, fade and a slight
/// shrink — while the bubble's own shape stays opaque and simply slides
/// back into (or out of) the attached shape.
private struct BubbleContentReveal: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = BubbleMotion.clamped(progress)
        content
            .scaleEffect(0.7 + 0.3 * p)
            .blur(radius: (1 - p) * 8)
            .opacity(p)
    }
}

/// Hides the whole bubble once it has merged back — read from the animated
/// value, so it flips at the end of the merge instead of fading through it.
/// The threshold is well above zero on purpose: by 4% of the way out the
/// bubble is entirely tucked inside the attached shape, and waiting for the
/// animation's long tail to reach exactly 0 left an empty circle lingering
/// (and drifting with the row) after the merge was visually done.
private struct BubbleHiddenWhenMerged: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(progress > 0.04 ? 1 : 0)
    }
}
