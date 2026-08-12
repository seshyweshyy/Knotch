//
//  ContentView.swift
//  Knotch
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

struct MusicLiveActivity: View {
    @ObservedObject var musicManager = MusicManager.shared
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @Default(.playerColorTinting) var playerColorTinting
    @Default(.sneakPeekStyles) var sneakPeekStyles
    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.notchAppearanceStyle) var notchAppearanceStyle

    let albumArtNamespace: Namespace.ID

    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var rotationDegrees: Double = 0
    @State private var flipBlur: CGFloat = 0
    @State private var flipBrightness: Double = 0

    // When glass is active, the middle strip should let the shared notch
    // background (glass + gradient mask) show through instead of covering
    // it with an opaque black rectangle.
    private var glassActive: Bool {
        notchAppearanceStyle == .semiLiquidGlass || notchAppearanceStyle == .fullLiquidGlass
    }

    // The placeholder icon has no "playing"/"paused" state of its own to
    // reflect — shrinking/dimming it in step with isPlaying would just read
    // as the icon itself flickering for no reason.
    private var showsPausedLook: Bool {
        !musicManager.isPlaying && displayedArt !== noArtworkPlaceholderImage
    }

    private var artSize: CGFloat {
        max(0, (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music)
            ? vm.effectiveClosedNotchHeight - 4   // slightly bigger during sneak peek
            : vm.effectiveClosedNotchHeight - 12)
    }


    var body: some View {
        HStack {
            Image(nsImage: displayedArt)
                .resizable()
                // Wide artwork (e.g. YouTube video thumbnails) has its own aspect
                // ratio, not 1:1 — scale to fit so the whole thumbnail stays
                // visible (letterboxed) instead of being cropped or squashed.
                .scaledToFit()
                // Round the letterboxed thumbnail itself, not just the square
                // frame around it — otherwise non-square art keeps sharp
                // corners since it no longer touches the frame's edges.
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed / 2)
                )
                // Overlay (rather than a same-size sibling shape) so the
                // paused dim always matches the image's own resolved bounds
                // — a plain square sibling stuck out past non-square (e.g.
                // YouTube thumbnail) art as a visible box.
                .overlay(
                    RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed / 2)
                        .foregroundColor(.black)
                        .opacity(showsPausedLook ? 0.3 : 0)
                        .allowsHitTesting(false)
                )
                .frame(width: artSize, height: artSize)
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                // Sat flush against the pill's leading edge with zero inset
                // outside the sneak-peek-active state (whose own conditional
                // padding above only applies during that state) — nudged in
                // a little so it doesn't anchor right at the corner.
                .padding(.leading, 5)
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: coordinator.sneakPeek.show)
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
                // Explicit, so this always eases smoothly regardless of whatever
                // (often much faster) animation duration wraps the isPlaying
                // change at the call site, matching the open notch/compact art.
                .scaleEffect(showsPausedLook ? 0.90 : 1)
                .animation(.smooth(duration: 0.35), value: showsPausedLook)

            Rectangle()
                .fill(glassActive ? Color.clear : Color.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            BlurRevealText(musicManager.songTitle) { title in
                                MarqueeText(
                                    .constant(title),
                                    font: .body.weight(.semibold),
                                    textColor: playerColorTinting
                                        ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                    minDuration: 0.4,
                                    frameWidth: 100
                                )
                            }
                            .opacity(
                                (coordinator.expandingView.show
                                    && sneakPeekStyles == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            BlurRevealText(musicManager.artistName, anchor: .trailing) { artist in
                                Text(artist)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundStyle(
                                        playerColorTinting
                                            ? Color(nsColor: musicManager.avgColor)
                                            : Color.gray
                                    )
                            }
                            .opacity(
                                (coordinator.expandingView.show
                                    && coordinator.expandingView.type == .music
                                    && sneakPeekStyles == .inline)
                                    ? 1 : 0
                            )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && sneakPeekStyles == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    AlbumArtWaveformMask(albumArt: displayedArt, isPlaying: $musicManager.isPlaying)
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(0, vm.effectiveClosedNotchHeight - 12),
                height: max(0, vm.effectiveClosedNotchHeight - 12),
                alignment: .center
            )
            .offset(x: (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music) ? -9 : -5)
        }
        // Only when the top corner curves inward to the concave 12pt (music
        // sneak peek) does the album art/waveform need edge padding — it sits
        // flush against the edges fine against the flat default (6pt) radius.
        // A HUD can no longer be showing concurrently with this view at all
        // (see ClosedRowFamily) — they're mutually exclusive row content now.
        .padding(.horizontal, (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music) ? 6 : 0)
        .frame(
            height: (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music)
                ? vm.effectiveClosedNotchHeight + 8
                : vm.effectiveClosedNotchHeight,
            alignment: .center
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: coordinator.sneakPeek.show)
    }
}

struct BatteryNotchBanner: View {
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @EnvironmentObject var vm: KnotchViewModel
    @Default(.notchAppearanceStyle) var notchAppearanceStyle

    private let bannerWidth: CGFloat = 280
    private let bannerContentHeight: CGFloat = 60

    // When glass is active, the genericBanner's middle strip should let the
    // shared notch background (glass + gradient mask) show through instead
    // of covering it with an opaque black rectangle.
    private var glassActive: Bool {
        notchAppearanceStyle == .semiLiquidGlass || notchAppearanceStyle == .fullLiquidGlass
    }

    private enum BannerKind: Equatable {
        case lowBattery
        case fullBattery
        case generic
    }

    private var kind: BannerKind {
        if batteryModel.levelBattery <= 20 && !batteryModel.isCharging && !batteryModel.isPluggedIn {
            return .lowBattery
        } else if batteryModel.levelBattery == 100 && (batteryModel.isCharging || batteryModel.isPluggedIn) {
            return .fullBattery
        } else {
            return .generic
        }
    }

    @State private var pulse = false
    @State private var showBatteryIndicator = false
    @State private var changeBatteryIndicator = true

    var body: some View {
        Group {
            if kind == .generic {
                genericBanner
            } else {
                standardBanner
            }
        }
        .onAppear(perform: prepareAnimations)
        .onChange(of: kind) { _, _ in
            // Same NSGlassEffectView backdrop staleness KnotchViewModel.open()
            // works around — genericBanner and standardBanner are very
            // different widths, so switching between them resizes the panel
            // just as much as an open/close does (see
            // KnotchSkyLightWindow.knotchWillOpen for the handler).
            NotificationCenter.default.post(name: .knotchWillOpen, object: nil)
            prepareAnimations()
        }
    }

    // Original slim pill — still used for the Low Power Mode toggle message
    private var genericBanner: some View {
        HStack(spacing: 0) {
            HStack {
                Text(batteryModel.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 110, alignment: .leading)

            Rectangle()
                .fill(glassActive ? Color.clear : Color.black)
                .frame(width: vm.closedNotchSize.width + 40)

            HStack {
                KnotchBatteryView(
                    batteryWidth: 30,
                    isCharging: batteryModel.isCharging,
                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                    isPluggedIn: batteryModel.isPluggedIn,
                    levelBattery: batteryModel.levelBattery,
                    isForNotification: true
                )
            }
            .frame(width: 76, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    // Takeover banner for low/full battery
    private var standardBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: kind == .lowBattery ? 2 : 3) {
                title
                description
            }
            .padding(.leading, kind == .lowBattery ? 40 : 35)
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            indicator
                .padding(.leading, 15)
                .padding(.trailing, kind == .lowBattery ? 45 : 40)
        }
        .frame(width: bannerWidth, height: bannerContentHeight)
        .padding(.top, vm.effectiveClosedNotchHeight)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var title: some View {
        HStack(spacing: 5) {
            Text(verbatim: kind == .lowBattery ? "Battery Low" : "Full Battery")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            Text("\(Int(batteryModel.levelBattery))%")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind == .lowBattery
                    ? (batteryModel.isInLowPowerMode ? .yellow : .red)
                    : (batteryModel.isInLowPowerMode ? .yellow : .green))
        }
    }

    @ViewBuilder
    private var description: some View {
        switch kind {
        case .lowBattery:
            if batteryModel.isInLowPowerMode {
                (
                    Text(verbatim: "Low Power Mode enabled,")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10, weight: .medium))
                    +
                    Text(verbatim: "\nit is recommended to charge it.")
                        .foregroundColor(.gray.opacity(0.6))
                        .font(.system(size: 10, weight: .medium))
                )
                .lineLimit(2)
            } else {
                Text(verbatim: "Turn on Low Power Mode or it\nis recommended to charge it.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray.opacity(0.6))
                    .lineLimit(2)
            }
        case .fullBattery:
            Text(verbatim: "Your Mac is fully charged.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray.opacity(0.6))
                .lineLimit(1)
        case .generic:
            EmptyView()
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch kind {
        case .lowBattery:
            if batteryModel.isInLowPowerMode {
                yellowLowIndicator
            } else {
                redLowIndicator
            }
        case .fullBattery:
            if showBatteryIndicator {
                if batteryModel.isInLowPowerMode {
                    yellowFullIndicator
                        .transition(.opacity.combined(with: .scale))
                } else {
                    greenFullIndicator
                        .transition(.opacity.combined(with: .scale))
                }
            } else {
                magSafeIndicator
                    .transition(.opacity.combined(with: .scale))
            }
        case .generic:
            EmptyView()
        }
    }

    private var redLowIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.red.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.4))
                    .frame(width: 40, height: 24)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
            .padding(.trailing, 5)

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.gradient)
                .frame(width: 8, height: 14)
                .opacity(pulse ? 1 : 0.3)
                .offset(x: -15)

            RoundedRectangle(cornerRadius: 30)
                .stroke(Color.red.opacity(0.9), lineWidth: 1.5)
                .frame(width: pulse ? 8 : 30, height: pulse ? 14 : 32)
                .offset(x: -15)
                .opacity(pulse ? 0.3 : 1)
        }
    }

    private var yellowLowIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.yellow.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 40, height: 24)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
            .padding(.trailing, 5)

            RoundedRectangle(cornerRadius: 8)
                .fill(.yellow.gradient)
                .frame(width: 8, height: 14)
                .offset(x: -15)
        }
    }

    private var greenFullIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.green.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.green.opacity(0.4))
                    .frame(width: 44, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.gradient)
                            .frame(width: 34, height: 14)
                            .opacity(pulse ? 1 : 0.4)
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(.green.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
        }
    }

    private var yellowFullIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.yellow.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 44, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.yellow.gradient)
                            .frame(width: 34, height: 14)
                            .opacity(pulse ? 1 : 0.4)
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
        }
    }

    private var magSafeIndicator: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.gray.opacity(0.15))
                .frame(width: 30, height: 5)

            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.gray.opacity(0.2).gradient)
                    .frame(width: 30, height: 40)

                Circle()
                    .fill(changeBatteryIndicator ? .orange : .green)
                    .shadow(color: changeBatteryIndicator ? .orange : .green, radius: 5)
                    .frame(width: 5, height: 5)
            }

            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 3, height: 32)
        }
    }

    private func prepareAnimations() {
        pulse = false
        showBatteryIndicator = kind == .fullBattery
        changeBatteryIndicator = true

        switch kind {
        case .generic:
            break
        case .lowBattery:
            if !batteryModel.isInLowPowerMode {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        case .fullBattery:
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.spring(duration: 0.4)) {
                    showBatteryIndicator = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.spring(duration: 0.2)) {
                    changeBatteryIndicator = false
                }
            }
        }
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var timerManager = TimerManager.shared

    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var hasTriggeredSwipe = false
    @State private var hasTriggeredHorizontalSwipe = false
    // Real glass background size from the GeometryReader below — drives mask
    // selection off actual geometry instead of a guessed close-spring delay.
    @State private var measuredGlassSize: CGSize = .zero
    // Blocks a momentum-scroll tail from re-arming a second skip after a real one fires.
    @State private var horizontalSwipeCooldownUntil: Date = .distantPast
    @State private var lockedView: NotchViews? = nil
    // Tracks whether the closed-notch sneak peek title is actually scrolling,
    // so the edge fade (sized for scrolling/truncated text) only shows up
    // when there's scrolling text to soften — not over a short, centered title.
    @State private var sneakPeekTitleScrolling = false

    @State private var gestureProgress: CGFloat = .zero
    // Base height to scale/restore from during a close-swipe. Safe to mutate
    // vm.notchSize.height live (unlike width) — it's a fixed constant per UI
    // mode, no reactive observer fighting over it.
    @State private var closeSwipeBaseHeight: CGFloat = 0
    // True only between a real .began/.ended pair for the up-swipe. PanGesture
    // fires a phantom handleUpGesture(0, .ended) on every down-swipe too
    // (see PanGesture.swift) — without this flag that stomped notchSize.height.
    @State private var isCloseSwipeActive = false

    // 0...1 fraction through the swipe-up close gesture. closeSwipeBlur and
    // closeSwipeSquish both derive from this so tuning one doesn't rescale
    // the other's timing.
    private var closeSwipeProgress: CGFloat {
        max(0, min(-gestureProgress, 20)) / 20
    }

    // Lower than the 20pt mount-transition blur (AnyTransition.blur) —
    // 20pt read as too heavy for the live drag.
    private var closeSwipeBlur: CGFloat {
        closeSwipeProgress * 8
    }

    // Flatten ratio for the close-swipe — real notchSize.height multiplier
    // in handleUpGesture, plus a cosmetic scaleEffect on KnotchHeader (whose
    // height doesn't come from notchSize). Eased so it shows early in the drag.
    private var closeSwipeSquish: CGFloat {
        let eased = (1.5 * closeSwipeProgress) / (0.5 + closeSwipeProgress)
        return 1 - eased * 0.14
    }


    @State private var haptics: Bool = false
    
    @State private var isUnlockAnimating: Bool = false
    @EnvironmentObject private var lockAnimationHost: LockAnimationHost
    
    @State private var bluetoothHUDExpanded: Bool = false
    @State private var airdropHUDExpanded: Bool = false

    // Alcove-style collapse/expand between the closed-notch HUD and the
    // persistent live activities (music/timer) — see desiredRowFamily below.
    // displayedRowFamily lags desiredRowFamily on purpose: it only jumps to
    // match once rowMorph has collapsed all the way to 0, so the swap itself
    // happens while the row is scaled/blurred down to invisible.
    @State private var displayedRowFamily: ClosedRowFamily = .none
    @State private var rowMorph: CGFloat = 1
    // Bumped on every desiredRowFamily change; a pending collapse->swap->expand
    // Task checks this before acting, so a rapid retrigger (e.g. holding the
    // volume key) cancels the older, now-stale swap instead of both firing.
    @State private var rowTransitionGeneration = 0

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var activeCornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) {
        Defaults[.enableCompactUI] ? compactCornerRadiusInsets : cornerRadiusInsets
    }

    // Continuously blends between the bare closed pill's radius and whichever
    // family is currently displayed's own resting radius, by rowMorph — at
    // rowMorph == 1 (steady state, no transition in flight) this reduces to
    // exactly the value each family always used, so nothing changes at rest;
    // during a family swap it interpolates smoothly through the bare-notch
    // radius at the collapsed midpoint instead of snapping, in lockstep with
    // ClosedNotchRowContent's own scale/blur (both driven by the same rowMorph).
    private var topCornerRadius: CGFloat {
        guard vm.notchState == .closed else {
            return activeCornerRadiusInsets.opened.top
        }
        let bareTop = activeCornerRadiusInsets.closed.top
        let blended = bareTop + (restingTopCornerRadius - bareTop) * rowMorph
        // The Default-style HUD's own independent second row (see
        // defaultStyleHUDShowing) sits outside the row-family system, but
        // still needs the same concave top the music sneak peek/Default-style
        // .hud family used to give it, regardless of what row 1 is currently
        // showing above it.
        return defaultStyleHUDShowing ? max(blended, 12) : blended
    }

    // The radius displayedRowFamily's content rests at once fully expanded —
    // same special-case values topCornerRadius always used, centralized here.
    private var restingTopCornerRadius: CGFloat {
        switch displayedRowFamily {
        case .hud:
            // A milder version of Compact mode's big notch-hugging top radius
            // (35) — applied regardless of whether Compact mode itself is on,
            // so the expanded AirDrop/Bluetooth card always gets it.
            if coordinator.sneakPeek.type == .airdropReceive {
                return airdropHUDExpanded ? 26 : activeCornerRadiusInsets.closed.top
            }
            if coordinator.sneakPeek.type == .bluetoothAudio {
                return bluetoothHUDExpanded ? 26 : activeCornerRadiusInsets.closed.top
            }
            // Default-style HUDs no longer reach this family at all (they're
            // an independent second row now — see defaultStyleHUDShowing's
            // own contribution to topCornerRadius below), so this is always
            // an Inline-style HUD here, which keeps the plain closed radius.
            return activeCornerRadiusInsets.closed.top
        case .music:
            // Only the active title/artist marquee reveal gets the concave
            // treatment (same as the Default HUD card, scaled down for this
            // much smaller pill) — the plain persistent bar, showing most of
            // the time with no reveal active, keeps the ordinary closed
            // radius. Matches topCornerRadius's original condition exactly
            // (it required sneakPeek.show, not just "music is the family").
            return (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music)
                ? 12 : activeCornerRadiusInsets.closed.top
        case .battery:
            // Same concave treatment as the expanded Bluetooth/AirDrop cards
            // above — only the low/full-battery takeover card (not the
            // low-power-mode toggle message) is tall enough to need it.
            // Matches restingBottomCornerRadius's isStandardBanner check.
            let batteryModel = BatteryStatusViewModel.shared
            let isStandardBanner = (batteryModel.levelBattery <= 20 && !batteryModel.isCharging && !batteryModel.isPluggedIn)
                || (batteryModel.levelBattery == 100 && (batteryModel.isCharging || batteryModel.isPluggedIn))
            return isStandardBanner ? 26 : activeCornerRadiusInsets.closed.top
        case .timer, .none, .lock:
            return activeCornerRadiusInsets.closed.top
        }
    }

    // Matches the condition that shows MusicLiveActivity below — the
    // persistent closed-state music bar isn't part of vm.notchState == .open
    // or coordinator.sneakPeek.show, so it needs its own check to get glass.
    private var musicLiveActivityShowing: Bool {
        (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed
            && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled
            && !vm.hideOnClosed
    }

    // Matches the condition that shows BatteryNotchBanner below — it's
    // driven by coordinator.expandingView, not coordinator.sneakPeek, so
    // it isn't covered by glassVisible's sneakPeek.show check either.
    private var batteryBannerShowing: Bool {
        coordinator.expandingView.type == .battery
            && coordinator.expandingView.show
            && vm.notchState == .closed
            && Defaults[.showPowerStatusNotifications]
    }

    // Matches the condition that shows TimerCompactPill below — the
    // persistent closed-state timer pill isn't part of vm.notchState == .open
    // or coordinator.sneakPeek.show, so it needs its own check to get glass.
    private var timerLiveActivityShowing: Bool {
        vm.notchState == .closed
            && !TimerManager.shared.allTimers.isEmpty
            && !TimerManager.shared.isPausedIdle
            && !vm.hideOnClosed
    }

    // Matches the condition that shows LockNotchOverlay below — it's driven
    // by vm.isScreenLocked/isUnlockAnimating, not coordinator.sneakPeek, so
    // it isn't covered by glassVisible's sneakPeek.show check either.
    private var lockActivityShowing: Bool {
        Defaults[.showOnLockScreen] && (vm.isScreenLocked || isUnlockAnimating)
    }

    // Default-style (non-inline) volume/brightness/mic/backlight/focus HUDs
    // don't take over the row-1 slot at all — they compose as their own
    // independent second row instead, underneath whatever row 1 (a live
    // activity, the lock icon, nothing) is already showing, matching how
    // this always used to look before HUD/live-activity collapse-and-expand
    // existed. Bluetooth/AirDrop and Inline-style HUDs are excluded here —
    // they still take the row-1 slot exclusively (see desiredRowFamily),
    // since their own layout structurally can't coexist with row 1's.
    private var defaultStyleHUDShowing: Bool {
        coordinator.sneakPeek.show
            && coordinator.sneakPeek.type != .music
            && coordinator.sneakPeek.type != .battery
            && coordinator.sneakPeek.type != .bluetoothAudio
            && coordinator.sneakPeek.type != .airdropReceive
            && !Defaults[.inlineHUD]
            && vm.notchState == .closed
    }

    // Which family (HUD vs. lock vs. battery banner vs. music vs. timer live
    // activity) currently wants the closed-notch row slot. displayedRowFamily
    // (in body) tracks this with a lag, only jumping to match once rowMorph
    // has collapsed fully — see the .onChange(of: desiredRowFamily) handler
    // below.
    //
    // Priority: an active Bluetooth/AirDrop/Inline-style HUD always wins,
    // even while locked — whatever was showing collapses in and the HUD
    // expands out in its place, then collapses back to let it expand back
    // out once the HUD ends. A Default-style HUD never reaches this at all —
    // see defaultStyleHUDShowing above — so row 1 keeps showing whatever it
    // already would underneath it. Otherwise, being locked wins over the
    // battery banner and any live activity — all of them stay hidden while
    // locked, matching how the lock icon used to take over exclusively. The
    // battery banner in turn outranks music/timer (matching its original
    // priority, checked right after lock/before everything else) — same
    // collapse-in/expand-out treatment applies to every one of these
    // transitions now, not just the ones already wired up.
    private var desiredRowFamily: ClosedRowFamily {
        guard vm.notchState == .closed, !coordinator.helloAnimationRunning
        else { return .none }
        if coordinator.sneakPeek.show && coordinator.sneakPeek.type != .music && coordinator.sneakPeek.type != .battery
            && !defaultStyleHUDShowing
        {
            return .hud
        }
        if lockActivityShowing { return .lock }
        if batteryBannerShowing { return .battery }
        if musicLiveActivityShowing { return .music }
        if timerLiveActivityShowing { return .timer }
        return .none
    }

    // Same blend-by-rowMorph treatment as topCornerRadius above — hello/open
    // keep their own unconditional values (untouched by any row family swap),
    // everything else (including the battery banner now) continuously
    // interpolates toward/away from displayedRowFamily's resting radius.
    private var currentBottomCornerRadius: CGFloat {
        if coordinator.helloAnimationRunning { return 28 }
        if vm.notchState == .open {
            // Kept small — the album art hugs this corner with minimal padding,
            // so a larger boost here clips straight into it during a hard pull.
            return activeCornerRadiusInsets.opened.bottom + vm.liquidPull * 0.05
        }

        let bareBottom = activeCornerRadiusInsets.closed.bottom
        let blended = bareBottom + (restingBottomCornerRadius - bareBottom) * rowMorph
        // Same independent contribution as topCornerRadius above.
        return defaultStyleHUDShowing ? max(blended, 22) : blended
    }

    // The radius displayedRowFamily's content rests at once fully expanded —
    // same special-case values currentBottomCornerRadius always used.
    private var restingBottomCornerRadius: CGFloat {
        switch displayedRowFamily {
        case .hud:
            if coordinator.sneakPeek.type == .bluetoothAudio {
                return bluetoothHUDExpanded ? 28 : activeCornerRadiusInsets.closed.bottom + 3
            }
            if coordinator.sneakPeek.type == .airdropReceive {
                return airdropHUDExpanded ? 28 : activeCornerRadiusInsets.closed.bottom + 4
            }
            // Always an Inline-style HUD here now — see restingTopCornerRadius's
            // matching comment.
            return isHovering ? activeCornerRadiusInsets.closed.bottom + 6 : activeCornerRadiusInsets.closed.bottom
        case .music:
            // Same sneakPeek.show gating as restingTopCornerRadius above —
            // this bug (persistent music bar's bottom corners over-rounded
            // to 22pt at all times) was from unconditionally returning 22
            // for the whole .music family instead of just the active reveal.
            return (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music)
                ? 26 : activeCornerRadiusInsets.closed.bottom
        case .battery:
            // Matches the original isExpandedBatteryBanner check — only the
            // low/full-battery takeover card (not the low-power-mode toggle
            // message) gets the deeper concave radius.
            let batteryModel = BatteryStatusViewModel.shared
            let isStandardBanner = (batteryModel.levelBattery <= 20 && !batteryModel.isCharging && !batteryModel.isPluggedIn)
                || (batteryModel.levelBattery == 100 && (batteryModel.isCharging || batteryModel.isPluggedIn))
            return isStandardBanner ? 28 : activeCornerRadiusInsets.closed.bottom
        case .timer, .none, .lock:
            return activeCornerRadiusInsets.closed.bottom
        }
    }

    private var currentNotchShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: currentBottomCornerRadius)
    }

    // The closed-notch row's own current width — continuously interpolated
    // between the bare notch width and displayedRowFamily's resting width by
    // rowMorph (this now covers the locked/lock-icon state too, via
    // ClosedRowFamily.lock). Shared with computedChinWidth (the invisible
    // hit-rect) — both need the exact same value ClosedNotchRowContent's own
    // `rowWidth` computes internally, so the two can't drift apart.
    private var rowContentWidth: CGFloat {
        // The floor (matches ClosedNotchRowContent's own bareWidth) vs. the
        // raw width fed into restingRowWidth's formulas (matches its own
        // restingWidth) are deliberately different values now — see the
        // comments on both.
        let bare = vm.closedNotchSize.width - 20
        let resting = restingRowWidth(
            for: displayedRowFamily,
            sneakPeekType: coordinator.sneakPeek.type,
            closedNotchWidth: vm.closedNotchSize.width,
            effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight,
            bluetoothHUDExpanded: bluetoothHUDExpanded,
            airdropHUDExpanded: airdropHUDExpanded,
            isHovering: isHovering
        )
        return bare + (resting - bare) * rowMorph
    }

    private var computedChinWidth: CGFloat {
        guard vm.notchState == .closed else { return vm.closedNotchSize.width }
        return rowContentWidth
    }
    
    private var semiLiquidGlassTransition: Double {
        Defaults[.semiLiquidGlassTransition]
    }

    private var semiLiquidGlassGradientMask: LinearGradient {
        // semiLiquidGlassTransition is the "glass amount" (0 = none, 0.8 = max).
        // The mask logic below is driven by "black amount" instead, so invert it.
        let glassAmount: Double = semiLiquidGlassTransition
        let transition: Double = 1 - glassAmount

        let fadeStart: Double = max(0, transition - 0.15)
        let fadeEnd: Double = min(1, transition + 0.15)
        let mid: Double = (fadeStart + fadeEnd) / 2

        let stops: [Gradient.Stop] = [
            .init(color: .black, location: 0),
            .init(color: .black, location: fadeStart),
            .init(color: .black.opacity(0.6), location: mid),
            .init(color: .clear, location: fadeEnd),
            .init(color: .clear, location: 1)
        ]

        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    // The persistent closed-state music bar is much shorter than the open
    // notch, so the user-configurable semiLiquidGlassGradientMask (tuned for
    // the open state) reads as mostly-glass there. This pushes the black
    // region further down, keeping only a thin hint of glass at the bottom
    // edge, independent of the Semi Liquid Glass Amount slider.
    private var closedLiquidGlassGradientMask: LinearGradient {
        let stops: [Gradient.Stop] = [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.7),
            .init(color: .black.opacity(0.6), location: 0.8),
            .init(color: .clear, location: 0.9),
            .init(color: .clear, location: 1)
        ]

        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScaleY: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        // x stays 1 while closing (gestureProgress < 0) — width shouldn't
        // shrink alongside the real notchSize.height change in handleUpGesture.
        // Pull-down-to-open bounce (positive progress) is untouched.
        let gestureScaleX: CGFloat = gestureProgress < 0 ? 1.0 : gestureScaleY
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Single source of truth for the panel's target width/height,
                // fed into NotchGeometryModifier below alongside the corner
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? cornerRadiusInsets.opened.top
                        // NotchShape's straight side walls sit inset by exactly
                        // `topCornerRadius` from this padded box's own edge (see
                        // NotchShape.path — the vertical edges are at minX+top /
                        // maxX-top for the shape's whole height). The old fixed
                        // 14pt was really "6pt corner radius + 8pt of slack" for
                        // the plain closed state; scaling with the current
                        // (dynamic) topCornerRadius keeps that same slack once
                        // sneak-peek/HUD states raise it (12, 26, ...) instead of
                        // the gap shrinking — and the content behind it clipping
                        // tighter — every time the concave radius grows.
                        : topCornerRadius + (cornerRadiusInsets.closed.bottom - cornerRadiusInsets.closed.top)
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background {
                        ZStack {
                            let glassVisible = vm.notchState == .open || coordinator.sneakPeek.show || musicLiveActivityShowing || batteryBannerShowing || timerLiveActivityShowing || lockActivityShowing
                            let semiGlassActive = Defaults[.notchAppearanceStyle] == .semiLiquidGlass && glassVisible
                            let fullGlassActive = Defaults[.notchAppearanceStyle] == .fullLiquidGlass && glassVisible

                            // Tracks the glass background's real rendered size live, for the mask switch below.
                            Color.clear
                                .background(GeometryReader { geo in
                                    Color.clear
                                        .onAppear { measuredGlassSize = geo.size }
                                        .onChange(of: geo.size) { _, newSize in
                                            measuredGlassSize = newSize
                                        }
                                })

                            if #available(macOS 26, *), Defaults[.notchAppearanceStyle] != .solidBlack {
                                // Kept mounted at all times *for glass styles* —
                                // swapping it in/out creates a new NSGlassEffectView
                                // that animates in from its initial frame, causing
                                // the open drift/ghosting. That only matters while
                                // glassVisible/semiGlassActive can flip mid-bounce,
                                // which never happens for Solid Black (both are
                                // always false for it regardless of notchState) —
                                // gating the mount on the style itself, which only
                                // ever changes from Settings, lets Solid Black skip
                                // creating the glass view at all instead of just
                                // hiding it behind an opaque cover.
                                KnotchLiquidGlass(
                                    shape: .notch(
                                        topCornerRadius: topCornerRadius,
                                        bottomCornerRadius: currentBottomCornerRadius
                                    )
                                )
                                Color.black
                                    .opacity(semiGlassActive || fullGlassActive ? 0 : 1)
                                    // Snapped instantly — fading it briefly exposes
                                    // the raw glass (and what's behind the notch).
                                    .transaction { $0.disablesAnimations = true }
                            } else {
                                Color.black
                            }

                            if #available(macOS 26, *) {
                                // Also kept unconditionally mounted (see above) —
                                // gating this on semiGlassActive meant it didn't
                                // exist while closed with no live activity, so
                                // opening from that state had to insert all three
                                // views mid-bounce, leaving the glass briefly
                                // uncovered. Opacity now carries
                                // semiGlassActive/fullGlassActive instead of
                                // presence.
                                // Snapped instantly, same as the cover above —
                                // without this, these kept fading out over the
                                // close spring's full duration instead of
                                // matching the cover's own instant snap to
                                // opaque, so they lingered on top of it and
                                // read as the close "fading" right at the end.
                                // Gated on measured size, not vm.notchState — notchState flips
                                // instantly on close, well before the frame visually shrinks.
                                // Checked against the true open height rather than the tiny
                                // pill's own height: the original tiny-pill-only threshold only
                                // classified the smallest pill as "closed-style" — Bluetooth/
                                // AirDrop's expanded HUD cards (~86-134pt, well short of the
                                // ~190pt open panel but much taller than the pill) fell through
                                // to the open-tuned mask and read as mostly glass instead of the
                                // opaque pill look every other closed-state card gets.
                                let isFrameSmall = measuredGlassSize.height < openNotchHomeSize.height * 0.8
                                let closedMaskActive = semiGlassActive && vm.notchState == .closed && isFrameSmall
                                let semiMaskActive = semiGlassActive && !closedMaskActive
                                Color.black
                                    .mask { closedLiquidGlassGradientMask }
                                    .opacity(closedMaskActive ? 1 : 0)
                                    .transaction { $0.disablesAnimations = true }
                                Color.black
                                    .mask { semiLiquidGlassGradientMask }
                                    .opacity(semiMaskActive ? 1 : 0)
                                    .transaction { $0.disablesAnimations = true }
                                Color.black
                                    .opacity(semiGlassActive ? 0.25 : 0)
                                    .transaction { $0.disablesAnimations = true }
                                Color.black
                                    .opacity(fullGlassActive ? 0.25 : 0)
                                    .transaction { $0.disablesAnimations = true }
                            }
                        }
                    }
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .scaleEffect(
                        x: vm.hudOvershootScale, y: 1,
                        anchor: UnitPoint(x: vm.hudOvershootAnchorX, y: 0.5)
                    )
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: 6
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(
                        width: vm.notchState == .open ? vm.notchSize.width + abs(vm.liquidPullHorizontal) * 0.7 : nil,
                        height: coordinator.helloAnimationRunning
                            ? 150
                            : (vm.notchState == .open ? vm.notchSize.height + vm.liquidPull * 0.4 : nil),
                        alignment: .top
                    )
                    .offset(x: vm.liquidPullHorizontal * 0.25)
                    // No ambient .animation(_:value:) for vm.notchState —
                    // KnotchViewModel.open()/close() wrap their own state
                    // changes in explicit withAnimation(...) now.
                    .animation(.smooth, value: gestureProgress)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .left) { translation, phase in
                                handleHorizontalGesture(translation: translation, phase: phase, sign: -1)
                            }
                            .panGesture(direction: .right) { translation, phase in
                                handleHorizontalGesture(translation: translation, phase: phase, sign: 1)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !self.vm.isMediaOutputPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.isMediaOutputPopoverActive) {
                        if !vm.isMediaOutputPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isMediaOutputPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.isScreenLocked) { _, newLocked in
                        if !newLocked && Defaults[.showOnLockScreen] {
                            isUnlockAnimating = true
                            // Was previously reset from inside
                            // LockNotchOverlay's own onChange, but that view
                            // is only mounted while ClosedRowFamily == .lock —
                            // if a HUD is occupying the row at the exact
                            // moment of unlock (e.g. it was still showing
                            // while locked and hasn't auto-dismissed yet),
                            // LockNotchOverlay isn't mounted, its onChange
                            // never fires, and isUnlockAnimating gets stuck
                            // true forever. That kept lockActivityShowing
                            // (and therefore the lock icon) alive after the
                            // HUD closed even though the screen was already
                            // unlocked. This handler is always mounted
                            // regardless of row family, so it's the reliable
                            // place to both trigger the animation and reset
                            // the flag once it finishes.
                            lockAnimationHost.play(forward: true) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.70)) {
                                        isUnlockAnimating = false
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: coordinator.hudLimitBounceEvent) { _, newEvent in
                        vm.triggerHUDLimitBounce(rightEdge: newEvent.rightEdge)
                    }
                    .onChange(of: desiredRowFamily) { _, newFamily in
                        handleRowFamilyChange(to: newFamily)
                    }
                    .onAppear {
                        // Skip the morph choreography on first mount — nothing
                        // was showing a moment ago to collapse away from.
                        var noAnim = Transaction()
                        noAnim.disablesAnimations = true
                        withTransaction(noAnim) {
                            displayedRowFamily = desiredRowFamily
                            rowMorph = 1
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("Version \(version)")
                                .font(.footnote)
                        }
                        
                        Button {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        } label: {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                        
                        Divider()
                        
                        Button {
                            NSApp.terminate(nil)
                        } label: {
                            Label("Quit Knotch", systemImage: "xmark.rectangle")
                        }
                    }
                    // Explicitly centered within the full (fixed) window width, rather
                    // than relying on the ambient VStack/ZStack alignment above — the
                    // notch was drifting off-center slightly as its width animated
                    // between closed and open sizes.
                    .frame(width: windowSize.width, alignment: .center)
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScaleX,
            y: gestureScaleY,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    if !TimerManager.shared.isCreatingTimer {
                        coordinator.currentView = .tray
                    }
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: vm.notchState == .open ? .center : .leading) {
            VStack(alignment: vm.notchState == .open ? .center : .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 68
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 30)
                    Spacer()
                } else if vm.notchState == .open && !Defaults[.enableCompactUI] {
                    KnotchHeader()
                        .frame(height: max(24, vm.effectiveClosedNotchHeight))
                        .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                        .scaleEffect(x: 1, y: closeSwipeSquish, anchor: .top)
                        .blur(radius: closeSwipeBlur)
                        .liquidStretch(vm)
                        .transition(
                            .opacity
                            .combined(with: .blur(radius: 20))
                            .animation(.smooth(duration: 0.35))
                        )
                } else if vm.notchState == .closed {
                    // Bluetooth/AirDrop HUDs, InlineHUD (the "Default" HUD
                    // style's SystemEventIndicatorModifier is a separate
                    // second row below, not part of this), MusicLiveActivity,
                    // TimerCompactPill, the lock icon, and BatteryNotchBanner —
                    // exactly as before, just relocated into one family-
                    // switching, collapse/expand-aware view, so locking/
                    // unlocking or a battery banner triggering while something
                    // else is showing collapses it away and expands the new
                    // thing out (and back) instead of hard-cutting between
                    // separate branches. See ClosedNotchRowContent +
                    // desiredRowFamily/rowMorph above for the choreography.
                    ClosedNotchRowContent(
                        family: displayedRowFamily,
                        morph: rowMorph,
                        isUnlockAnimating: $isUnlockAnimating,
                        bluetoothHUDExpanded: $bluetoothHUDExpanded,
                        airdropHUDExpanded: $airdropHUDExpanded,
                        sneakPeekTitleScrolling: $sneakPeekTitleScrolling,
                        albumArtNamespace: albumArtNamespace,
                        isHovering: $isHovering,
                        gestureProgress: $gestureProgress
                    )
                } else {
                    Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                }

                // The "Default" HUD style's own independent second row —
                // composes underneath whatever row 1 is already showing
                // (a live activity, the lock icon, nothing) instead of
                // replacing it, matching how this always used to look before
                // HUD/live-activity collapse-and-expand existed. See
                // defaultStyleHUDShowing's own note on why this isn't part of
                // ClosedRowFamily.
                if defaultStyleHUDShowing {
                    SystemEventIndicatorModifier(
                        eventType: $coordinator.sneakPeek.type,
                        value: $coordinator.sneakPeek.value,
                        icon: $coordinator.sneakPeek.icon,
                        label: coordinator.sneakPeek.deviceName,
                        tintColor: coordinator.sneakPeek.accentColor,
                        sendEventBack: { newVal in
                            switch coordinator.sneakPeek.type {
                            case .volume:
                                VolumeManager.shared.setAbsolute(Float32(newVal))
                            case .brightness:
                                BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                            default:
                                break
                            }
                        }
                    )
                    // Tracks row 1's own current width (whatever's showing
                    // above it — music, timer, lock, the bare notch, even
                    // mid-transition) instead of a separately-tuned number of
                    // its own, just pulled in a little narrower than an exact
                    // match.
                    .frame(width: rowContentWidth * 0.92)
                    .padding(.bottom, 10)
                    .padding(.leading, 5)
                    .padding(.trailing, 12)
                    .transition(.opacity)
                }
            }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .animation(.easeInOut(duration: 0.25), value: timerLiveActivityShowing)
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        // NotchHomeView applies one stretch across its whole content
                        // group (standard or compact), so nothing drifts relative
                        // to its neighbors.
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .tray:
                        // The tray ("tray") is unreachable in Compact mode — fall
                        // back to the home content instead of ever showing it,
                        // regardless of how currentView got set.
                        if Defaults[.enableCompactUI] {
                            NotchHomeView(albumArtNamespace: albumArtNamespace)
                        } else {
                            TrayView()
                                .liquidStretch(vm)
                                // Drop-zone outlines are actual drag targets — keep
                                // their x-position fixed even though the shared
                                // header+content group leans sideways on a
                                // horizontal pull (liquidHorizontalGroup below).
                                .liquidHorizontalGroupExempt(vm)
                        }
                    }
                }
                // Pin content to the un-stretched target height so the liquid pull only
                // inflates the bezel around it — flexible children like the album art
                // image would otherwise grow into the offered extra height and get
                // clipped by the shape's rounded top corner.
                .frame(maxWidth: .infinity, maxHeight: vm.notchSize.height, alignment: .top)
                // No more width transition between home and tray — notchSize
                // is the same (computedHomeSize) for both now, so there's
                // nothing left for this to react to.
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .combined(with: .blur(radius: 20))
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                .blur(radius: closeSwipeBlur)
            }
        }
        // Shared across the whole header+content group so a left/right pull
        // leans everything together in one direction, instead of each widget
        // independently bulging from its own edge (which the per-widget
        // vertical stretch below is fine doing, since nothing overlaps there).
        .liquidHorizontalGroup(vm)
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.knotchTray] && vm.notchState == .closed && !Defaults[.enableCompactUI] {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            TrayStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        guard !vm.isScreenLocked else { return }
        // open() drives its own animation internally now.
        vm.open()
    }

    // MARK: - Closed-notch row family transitions (HUD <-> live activity)

    // Drives the Alcove-style collapse/expand whenever the closed-notch row's
    // desired family (HUD vs. music vs. timer) changes. displayedRowFamily
    // only jumps to the new value once rowMorph has fully collapsed — see
    // ClosedNotchRowContent, whose scale/blur/opacity are all driven by the
    // same rowMorph this animates.
    private func handleRowFamilyChange(to newFamily: ClosedRowFamily) {
        rowTransitionGeneration += 1
        let myGeneration = rowTransitionGeneration

        // Only the expand-out step for volume/brightness specifically runs
        // quicker — collapsing away (whether it's volume/brightness or
        // anything else) and every other family's own expand stay on
        // rowMorphSpring's normal timing.
        let expandSpring = (newFamily == .hud
            && (coordinator.sneakPeek.type == .volume || coordinator.sneakPeek.type == .brightness))
            ? rowMorphFastSpring : rowMorphSpring

        if newFamily == displayedRowFamily {
            // Flipped back before a pending swap fired (e.g. a rapid
            // retrigger) — just make sure we're settled back at full scale;
            // there's no new content to swap to.
            withAnimation(expandSpring) { rowMorph = 1 }
            return
        }

        // Always run the same collapse -> swap -> expand choreography, even
        // when one side is .none (nothing showing) — a HUD ending with no
        // live activity to fall back to should still collapse into the
        // notch, not just crossfade/fade out in place the old way.
        withAnimation(rowMorphSpring) { rowMorph = 0 }
        // Same NSGlassEffectView backdrop staleness KnotchViewModel.open()
        // works around — this collapse resizes the panel same as an
        // open/close does (see KnotchSkyLightWindow.knotchWillOpen).
        NotificationCenter.default.post(name: .knotchWillOpen, object: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(rowMorphSwapDelay))
            guard myGeneration == rowTransitionGeneration else { return }
            var noAnim = Transaction()
            noAnim.disablesAnimations = true
            withTransaction(noAnim) { displayedRowFamily = newFamily }
            NotificationCenter.default.post(name: .knotchWillOpen, object: nil)
            withAnimation(expandSpring) { rowMorph = 1 }
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  !vm.isScreenLocked,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !self.vm.isMediaOutputPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {

        if vm.notchState == .open {
            if phase == .began {
                hasTriggeredSwipe = false
                lockedView = nil
                return
            }

            if phase == .ended {
                // Not gated on isHoveringCalendar — that used to leave
                // liquidPull stuck at its peak when the switch-view swipe
                // landed the cursor over the calendar on release.
                withAnimation(liquidReleaseSpring) { vm.liquidPull = .zero }
                if hasTriggeredSwipe {
                    gestureProgress = .zero
                } else {
                    withAnimation(animationSpring) { gestureProgress = .zero }
                }
                return
            }

            guard !vm.isHoveringCalendar else { return }

            // Liquid stretch follows the cursor 1:1 for the whole gesture, even after
            // the tab switch itself has already committed on the initial movement.
            // Clamped tighter while the timer ruler is up — its content doesn't
            // fill the extra height, so a full stretch left a visible gap below it.
            // Also toned down in Compact mode, whose smaller fixed panel doesn't
            // want the same amount of stretch as the standard layout.
            let pullClamp = TimerManager.shared.isCreatingTimer ? liquidPullClamp * 0.3
                : Defaults[.enableCompactUI] ? liquidPullClamp * 0.7
                : liquidPullClamp

            if hasTriggeredSwipe {
                // Hold the stretch at its peak instead of continuing to track raw
                // translation — a light/fast flick can trigger the swap on a tiny
                // movement, and tracking translation here would immediately stomp
                // the pop back down to that same tiny amount a frame later.
                vm.liquidPull = pullClamp
                return
            }

            vm.liquidPull = min(translation, pullClamp)

            if Defaults[.enableCompactUI] {
                // No tab concept in Compact mode — coordinator.currentView can
                // still drift to .tray (e.g. close() landing there once the
                // tray has items and openTrayByDefault is on), but Compact
                // mode always renders NotchHomeView regardless, so gating this
                // on .home would silently break swiping the moment the tray
                // stopped being empty. Only something to cycle between when
                // more than one compact page is reachable — music/calendar
                // per their own settings, plus tray once the tray actually
                // has items in it.
                if vm.availableCompactPages.count > 1 {
                    hasTriggeredSwipe = true
                    if Defaults[.enableHaptics] { haptics.toggle() }
                    withAnimation(animationSpring) {
                        vm.cycleCompactPage()
                        // Snapped to full stretch in the same animation as the
                        // toggle, so the shape's reactivity always lands in sync
                        // with the switch regardless of how light the gesture was.
                        vm.liquidPull = pullClamp
                    }
                }
            } else if Defaults[.swipeToCycleViews] && !TimerManager.shared.isCreatingTimer && !Defaults[.enableCompactUI] {
                let destination: NotchViews = coordinator.currentView == .home ? .tray : .home
                let destinationEnabled = destination == .home
                    ? Defaults[.showHomeView]
                    : Defaults[.showTrayView]
                if destinationEnabled {
                    lockedView = destination
                    hasTriggeredSwipe = true
                    if Defaults[.enableHaptics] { haptics.toggle() }
                    withAnimation(animationSpring) {
                        coordinator.currentView = destination
                        vm.liquidPull = pullClamp
                    }
                }
            }

            return
        }

        // CLOSED → OPEN (unchanged)
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] { haptics.toggle() }
            // Snapping this instantly (not via animationSpring) matters here:
            // mainLayout has two stacked .animation(_:value:) modifiers on the
            // same subtree — one keyed on gestureProgress, one keyed on
            // vm.notchState (the geometry spring doOpen() below triggers).
            // Stacking .animation(_:value:) with different trigger values on
            // the same view chain is unreliable in SwiftUI — when a fast
            // swipe crosses the threshold, gestureProgress is still mid-flight
            // from the ongoing animationSpring update just above, and
            // resetting it via ANOTHER withAnimation right as doOpen() fires
            // let the two compete over the same geometry, which is what made
            // the notch mask visibly lag on fast swipes but not slow ones
            // (a slow swipe crosses the threshold with gestureProgress much
            // closer to already settled, so there's less to collide over).
            var noAnimation = Transaction()
            noAnimation.disablesAnimations = true
            withTransaction(noAnimation) { gestureProgress = .zero }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open else { return }

        if phase == .began {
            isCloseSwipeActive = true
            closeSwipeBaseHeight = vm.notchSize.height
        }

        // Ignores phantom calls where this gesture never really started —
        // see isCloseSwipeActive's declaration.
        guard isCloseSwipeActive else { return }

        // Not gated on isHoveringCalendar up top, so it can't swallow the
        // .ended reset below.
        if !vm.isHoveringCalendar {
            withAnimation(animationSpring) {
                gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
                // Real height, not a cosmetic scaleEffect — the notch body itself flattens.
                vm.notchSize.height = closeSwipeBaseHeight * closeSwipeSquish
            }
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
                vm.notchSize.height = closeSwipeBaseHeight
            }
            isCloseSwipeActive = false
        }

        if !vm.isHoveringCalendar && translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose {
                gestureProgress = .zero
                isCloseSwipeActive = false
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    // Sideways stretch is cosmetic and always plays; the media-change setting
    // only gates whether crossing the threshold also skips a track.
    private func handleHorizontalGesture(translation: CGFloat, phase: NSEvent.Phase, sign: CGFloat) {
        guard vm.notchState == .open else { return }

        if phase == .began && Date() >= horizontalSwipeCooldownUntil {
            hasTriggeredHorizontalSwipe = false
        }

        if phase == .ended {
            // Not gated on isHoveringCalendar — same reasoning as the other
            // two gesture handlers, this reset must always run on release.
            if !Defaults[.enableCompactUI] {
                withAnimation(liquidReleaseSpring) { vm.liquidPullHorizontal = .zero }
            }
            MusicManager.shared.horizontalGestureSkipDirection = nil
            MusicManager.shared.horizontalGestureProgress = 0
            return
        }

        guard !vm.isHoveringCalendar else { return }

        if !Defaults[.enableCompactUI] {
            vm.liquidPullHorizontal = sign * min(translation, liquidPullClamp)
        }

        // sign > 0 = right swipe. Natural movement (default) treats right as back,
        // left as forward; off flips it, like macOS's natural-scrolling toggle.
        let isRightSwipeBack = Defaults[.naturalMediaGestureDirection]
        let goingBack = isRightSwipeBack ? sign > 0 : sign < 0

        // Stop updating once committed, or momentum scroll events after a real
        // skip flicker the button back into its pushed state.
        if Defaults[.changeMediaWithHorizontalGestures] && !hasTriggeredHorizontalSwipe {
            MusicManager.shared.horizontalGestureSkipDirection = goingBack ? .backward : .forward
            MusicManager.shared.horizontalGestureProgress = min(translation / Defaults[.gestureSensitivity], 1)
        }

        guard Defaults[.changeMediaWithHorizontalGestures],
              !hasTriggeredHorizontalSwipe,
              translation > Defaults[.gestureSensitivity]
        else { return }

        hasTriggeredHorizontalSwipe = true
        horizontalSwipeCooldownUntil = Date().addingTimeInterval(1.0)
        if Defaults[.enableHaptics] { haptics.toggle() }
        if goingBack {
            MusicManager.shared.previousTrack()
        } else {
            MusicManager.shared.nextTrack()
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

#Preview {
    let vm = KnotchViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
