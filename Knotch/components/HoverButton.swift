//
//  HoverButton.swift
//  Knotch
//
//  Created by Kraigo on 04.09.2024.
//

import Defaults
import SwiftUI

private enum SkipTriangleDirection {
    case forward
    case backward
}

enum HoverButtonAnimationEvent {
    case previousTrackSkip
    case nextTrackSkip
}

/// Notification with no publisher, used as a stable fallback so the `.onReceive`
/// publisher type stays consistent when a button has no external animation event.
private let hoverButtonAnimationNoop = Notification.Name("hoverButtonAnimationNoop")

/// Renders a skip icon as two independently animatable triangles (rather than a single
/// SF Symbol) so a tap can slide them through like a conveyor belt instead of just bouncing.
private struct SkipDoubleTriangleGlyph: View {
    let color: Color
    let pointSize: CGFloat
    let direction: SkipTriangleDirection
    let progress: CGFloat
    let isAnimating: Bool
    /// 0...1 pre-commit gesture preview — nudges the static pair together and forward.
    var pushProgress: CGFloat = 0

    private var triangleW: CGFloat { pointSize * 0.58 }
    private var triangleH: CGFloat { pointSize * 0.94 }

    var body: some View {
        let p = progress
        let pc = max(0, min(1, progress))
        let firstX = -triangleW * 0.5
        let secondX = triangleW * 0.5
        let spawnOffset = triangleW * 1.4
        let push = max(0, min(1, pushProgress))
        // Matches the conveyor slide's travel direction above.
        let pushShift = -triangleW * 0.32 * push
        let pushSqueeze = triangleW * 0.16 * push

        // Leaving and arriving triangles scale in lockstep with their own opacity fade,
        // so they visibly shrink into / grow out of nothing rather than sliding at full size.
        let firstFade = max(0.0, 1.0 - (pc * 2.4))
        let firstScale = firstFade
        let firstOpacity = firstFade
        let disappearingFirstX = firstX - (spawnOffset * (2.3 * p))
        let secondToFirstX = secondX + (firstX - secondX) * p
        let newSecondX = secondX + spawnOffset * (1 - p)
        let newSecondFade = min(1.0, pc * 1.35)
        let newSecondScale = newSecondFade
        let newSecondOpacity = newSecondFade

        Group {
            if isAnimating {
                ZStack {
                    triangle(offsetX: disappearingFirstX)
                        .scaleEffect(firstScale)
                        .opacity(firstOpacity)
                        .zIndex(3)
                    triangle(offsetX: secondToFirstX)
                        .zIndex(2)
                    triangle(offsetX: newSecondX)
                        .scaleEffect(newSecondScale)
                        .opacity(newSecondOpacity)
                        .zIndex(4)
                }
            } else {
                ZStack {
                    triangle(offsetX: firstX + pushSqueeze + pushShift)
                    triangle(offsetX: secondX - pushSqueeze + pushShift)
                }
            }
        }
        .frame(width: pointSize * 1.18, height: pointSize)
        .compositingGroup()
        .scaleEffect(x: direction == .forward ? 1 : -1, y: 1)
    }

    private func triangle(offsetX: CGFloat) -> some View {
        Image(systemName: "play.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: triangleW, height: triangleH)
            .scaleEffect(x: -1, y: 1)
            .offset(x: offsetX)
    }
}

/// Scales the whole button (icon + hover highlight) down the instant the mouse goes down,
/// and springs back on release, so the press reacts live rather than only after the click completes.
private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var iconScale: CGFloat = 1.0
    var animateOnTap: Bool = false
    var externalAnimationEvent: HoverButtonAnimationEvent? = nil
    /// 0...1 preview of an in-progress skip gesture — see `SkipDoubleTriangleGlyph.pushProgress`.
    var pushProgress: CGFloat = 0
    /// When non-nil, renders a small dot under the icon reflecting a toggle state (e.g. shuffle),
    /// instead of recoloring the icon itself. Animates in/out from behind the icon on change.
    var activeDot: Bool? = nil
    /// Horizontal nudge for the active dot, to line up with icons whose glyph isn't visually centered (e.g. shuffle).
    var activeDotXOffset: CGFloat = -1.5
    /// When true, the icon nudges up while `activeDot` is true, to clear space for the dot beneath it.
    var liftsIconWhenDotActive: Bool = false
    /// Finer-grained state to watch for the settle haptic, for toggles with sub-states that
    /// don't change `activeDot` itself but still deserve a tap (e.g. repeat: all -> one, where
    /// the dot stays visible throughout). Defaults to tracking `activeDot`'s own value.
    var hapticStateKey: Int? = nil
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect

    @State private var isHovering = false
    @State private var tapTransitionProgress: CGFloat = 0
    @State private var isTapTransitionActive = false
    @State private var activeDotHaptic = false

    private var isSkipIcon: Bool { icon == "forward.fill" || icon == "backward.fill" }

    var body: some View {
        let size = CGFloat(40)
        let iconPointSize: CGFloat = (scale == .large ? 34 : scale == .small ? 17 : 22) * iconScale
        let skipDirection: SkipTriangleDirection = (icon == "backward.fill") ? .forward : .backward
        let slideAnimation: Animation = .interpolatingSpring(stiffness: 235, damping: 20)
        let slideDuration: Double = 0.66
        let useSkipGlyph = animateOnTap && isSkipIcon
        let activeDotDiameter: CGFloat = 3
        let activeDotRestingOffset: CGFloat = iconPointSize / 2 + 1
        let activeDotSpring: Animation = .spring(response: 0.35, dampingFraction: 0.75)
        let activeDotSettleDuration: Double = 0.4
        let iconLiftAmount: CGFloat = 2
        let hapticWatchKey: Int = hapticStateKey ?? (activeDot == true ? 1 : 0)

        Button {
            if useSkipGlyph {
                runSkipAnimation(slideAnimation: slideAnimation, slideDuration: slideDuration)
            }
            action()
        } label: {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(isHovering ? Color.gray.opacity(0.2) : .clear)
                        .frame(width: size, height: size)
                        .overlay {
                            ZStack {
                                if let activeDot {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: activeDotDiameter, height: activeDotDiameter)
                                        .offset(x: activeDotXOffset, y: activeDot ? activeDotRestingOffset : 0)
                                        .opacity(activeDot ? 1 : 0)
                                        .scaleEffect(activeDot ? 1 : 0.3)
                                        .animation(activeDotSpring, value: activeDot)
                                        .zIndex(0)
                                }
                                Group {
                                    if useSkipGlyph {
                                        SkipDoubleTriangleGlyph(
                                            color: iconColor,
                                            pointSize: iconPointSize,
                                            direction: skipDirection,
                                            progress: tapTransitionProgress,
                                            isAnimating: isTapTransitionActive,
                                            pushProgress: isTapTransitionActive ? 0 : pushProgress
                                        )
                                        .animation(.easeOut(duration: 0.15), value: pushProgress)
                                    } else {
                                        Image(systemName: icon)
                                            .foregroundColor(iconColor)
                                            .contentTransition(contentTransition)
                                            .font(scale == .large ? .largeTitle : scale == .small ? .title3 : .title2)
                                    }
                                }
                                .offset(y: (liftsIconWhenDotActive && activeDot == true) ? -iconLiftAmount : 0)
                                .animation(activeDotSpring, value: activeDot)
                                .zIndex(1)
                            }
                        }
                }
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) {
                isHovering = hovering
            }
        }
        .onReceive(animationEventPublisher) { _ in
            guard useSkipGlyph else { return }
            runSkipAnimation(slideAnimation: slideAnimation, slideDuration: slideDuration)
        }
        .sensoryFeedback(.alignment, trigger: activeDotHaptic)
        .onChange(of: hapticWatchKey) { _, _ in
            guard activeDot == true, Defaults[.enableHaptics] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + activeDotSettleDuration) {
                activeDotHaptic.toggle()
            }
        }
    }

    private var animationEventPublisher: NotificationCenter.Publisher {
        switch externalAnimationEvent {
        case .previousTrackSkip:
            return NotificationCenter.default.publisher(for: .musicPreviousButtonAnimationTriggered)
        case .nextTrackSkip:
            return NotificationCenter.default.publisher(for: .musicNextButtonAnimationTriggered)
        case .none:
            return NotificationCenter.default.publisher(for: hoverButtonAnimationNoop)
        }
    }

    private func runSkipAnimation(slideAnimation: Animation, slideDuration: Double) {
        guard !isTapTransitionActive else { return }
        isTapTransitionActive = true
        tapTransitionProgress = 0
        withAnimation(slideAnimation) {
            tapTransitionProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + slideDuration) {
            tapTransitionProgress = 0
            isTapTransitionActive = false
        }
    }
}
