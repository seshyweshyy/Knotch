//
//  HoverButton.swift
//  Knotch
//
//  Created by Kraigo on 04.09.2024.
//

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

    private var triangleW: CGFloat { pointSize * 0.58 }
    private var triangleH: CGFloat { pointSize * 0.94 }

    var body: some View {
        let p = progress
        let pc = max(0, min(1, progress))
        let firstX = -triangleW * 0.5
        let secondX = triangleW * 0.5
        let spawnOffset = triangleW * 1.4

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
                    triangle(offsetX: firstX)
                    triangle(offsetX: secondX)
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

struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var iconScale: CGFloat = 1.0
    var enableBounce: Bool = true
    var animateOnTap: Bool = false
    var externalAnimationEvent: HoverButtonAnimationEvent? = nil
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect

    @State private var isHovering = false
    @State private var tapTrigger: Int = 0
    @State private var tapTransitionProgress: CGFloat = 0
    @State private var isTapTransitionActive = false

    private var isSkipIcon: Bool { icon == "forward.fill" || icon == "backward.fill" }

    var body: some View {
        let size = CGFloat(40)
        let iconPointSize: CGFloat = (scale == .large ? 34 : scale == .small ? 17 : 22) * iconScale
        let skipDirection: SkipTriangleDirection = (icon == "backward.fill") ? .forward : .backward
        let slideAnimation: Animation = .interpolatingSpring(stiffness: 235, damping: 20)
        let slideDuration: Double = 0.66
        let useSkipGlyph = animateOnTap && isSkipIcon

        Button {
            if useSkipGlyph {
                runSkipAnimation(slideAnimation: slideAnimation, slideDuration: slideDuration)
            } else {
                tapTrigger += 1
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
                            Group {
                                if useSkipGlyph {
                                    SkipDoubleTriangleGlyph(
                                        color: iconColor,
                                        pointSize: iconPointSize,
                                        direction: skipDirection,
                                        progress: tapTransitionProgress,
                                        isAnimating: isTapTransitionActive
                                    )
                                } else {
                                    Image(systemName: icon)
                                        .foregroundColor(iconColor)
                                        .contentTransition(contentTransition)
                                        .font(scale == .large ? .largeTitle : scale == .small ? .title3 : .title2)
                                        .symbolEffect(
                                            .bounce.down.byLayer,
                                            options: .nonRepeating,
                                            value: enableBounce ? tapTrigger : 0
                                        )
                                }
                            }
                        }
                }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) {
                isHovering = hovering
            }
        }
        .onReceive(animationEventPublisher) { _ in
            guard useSkipGlyph else { return }
            runSkipAnimation(slideAnimation: slideAnimation, slideDuration: slideDuration)
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
