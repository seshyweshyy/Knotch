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

    // Matches ContentView's own `defaultHUDShowing` — the "Default" HUD style's
    // volume/brightness card also bumps the shared top corner radius to the
    // same concave 12pt the music sneak peek uses, so this row (which can be
    // showing behind/alongside it, e.g. while music plays and a volume key is
    // pressed) needs the same edge padding to avoid the same crowding.
    private var defaultHUDShowing: Bool {
        coordinator.sneakPeek.show
            && coordinator.sneakPeek.type != .music
            && coordinator.sneakPeek.type != .battery
            && coordinator.sneakPeek.type != .bluetoothAudio
            && coordinator.sneakPeek.type != .airdropReceive
            && !Defaults[.inlineHUD]
            && vm.notchState == .closed
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
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: coordinator.sneakPeek.show)
                .rotation3DEffect(
                    .degrees(rotationDegrees),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.4
                )
                .onChange(of: musicManager.artFlipSignal) { _, signal in
                    let dir: Double = signal.direction == .forward ? 1 : -1

                    withAnimation(.easeIn(duration: 0.15)) {
                        rotationDegrees = dir * 90
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        displayedArt = signal.art
                        rotationDegrees = dir * -90
                        withAnimation(.easeOut(duration: 0.15)) {
                            rotationDegrees = 0
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
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                font: .body.weight(.semibold),
                                textColor: playerColorTinting
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && sneakPeekStyles == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            Text(musicManager.artistName)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    playerColorTinting
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
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
            .offset(x: (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music) ? -3 : -1.5)
        }
        // Only when the top corner curves inward to the concave 12pt (music
        // sneak peek, or the Default HUD style's volume/brightness card) does
        // the album art/waveform need edge padding — they sat flush against
        // the edges fine against the flat default (6pt) radius.
        .padding(.horizontal, ((coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music) || defaultHUDShowing) ? 6 : 0)
        .frame(
            height: (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music)
                ? vm.effectiveClosedNotchHeight + 8
                : vm.effectiveClosedNotchHeight,
            alignment: .center
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: coordinator.sneakPeek.show)
    }
}

private struct BatteryNotchBanner: View {
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
        .onChange(of: kind) { _, _ in prepareAnimations() }
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

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var activeCornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) {
        Defaults[.enableCompactUI] ? compactCornerRadiusInsets : cornerRadiusInsets
    }

    private var topCornerRadius: CGFloat {
            // A milder version of Compact mode's big notch-hugging top radius
            // (35) — applied here regardless of whether Compact mode itself
            // is on, so the expanded AirDrop card always gets it.
            if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .airdropReceive && airdropHUDExpanded {
                return 26
            }
            // Same concave treatment as the AirDrop expanded card, mirrored
            // for Bluetooth's expanded HUD.
            if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .bluetoothAudio && bluetoothHUDExpanded {
                return 26
            }
            // Same concave treatment, scaled down further for this much
            // smaller pill.
            if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music && vm.notchState == .closed {
                return 12
            }
            // The "Default" HUD style's card is the same kind of full-width,
            // full-height content as the music sneak peek — give it the same
            // concave top instead of the plain closed-notch/live-activity radius.
            if defaultHUDShowing {
                return 12
            }
            return vm.notchState == .open ? activeCornerRadiusInsets.opened.top : activeCornerRadiusInsets.closed.top
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
        let hudIsActive = coordinator.sneakPeek.show
            && coordinator.sneakPeek.type != .music
            && coordinator.sneakPeek.type != .bluetoothAudio
            && coordinator.sneakPeek.type != .airdropReceive
            && vm.notchState == .closed
        return Defaults[.showOnLockScreen] && (vm.isScreenLocked || isUnlockAnimating) && !hudIsActive
    }

    private var currentBottomCornerRadius: CGFloat {
        let batteryModel = BatteryStatusViewModel.shared
        let isExpandedBatteryBanner = coordinator.expandingView.type == .battery
            && coordinator.expandingView.show
            && Defaults[.showPowerStatusNotifications]
            && ((batteryModel.levelBattery <= 20 && !batteryModel.isCharging && !batteryModel.isPluggedIn)
                || (batteryModel.levelBattery == 100 && (batteryModel.isCharging || batteryModel.isPluggedIn)))

        return coordinator.helloAnimationRunning
            ? 28
            : vm.notchState == .open
                // Kept small — the album art hugs this corner with minimal padding,
                // so a larger boost here clips straight into it during a hard pull.
                ? activeCornerRadiusInsets.opened.bottom + vm.liquidPull * 0.05
                : coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music
                    ? 22
                    : coordinator.sneakPeek.show && coordinator.sneakPeek.type == .bluetoothAudio
                        ? bluetoothHUDExpanded ? 28 : activeCornerRadiusInsets.closed.bottom + 3
                            : coordinator.sneakPeek.show && coordinator.sneakPeek.type == .airdropReceive
                                ? airdropHUDExpanded ? 28 : activeCornerRadiusInsets.closed.bottom + 4
                            : isExpandedBatteryBanner
                                ? 28
                                // Same treatment as the music bar — this is the "Default"
                                // (non-inline) style's slider card, a similarly full-width,
                                // full-height piece of content, not the thin closed pill.
                                : defaultHUDShowing
                                    ? 22
                                    : inlineHUDShowing && isHovering
                                        ? activeCornerRadiusInsets.closed.bottom + 6
                                        : activeCornerRadiusInsets.closed.bottom
    }

    // Matches the condition that shows SystemEventIndicatorModifier below —
    // the "Default" HUD style's volume/brightness/mic/focus card, shown when
    // inline style is off and the type isn't one of the ones with their own
    // bespoke pill.
    private var defaultHUDShowing: Bool {
        coordinator.sneakPeek.show
            && coordinator.sneakPeek.type != .music
            && coordinator.sneakPeek.type != .battery
            && coordinator.sneakPeek.type != .bluetoothAudio
            && coordinator.sneakPeek.type != .airdropReceive
            && !Defaults[.inlineHUD]
            && vm.notchState == .closed
    }

    // Matches the condition that shows InlineHUD below (coordinator.sneakPeek
    // driven, Defaults[.inlineHUD] style, excluding the types with their own
    // bespoke pills) so the hover corner-radius bump only applies there —
    // not to the plain menu-bar-height closed notch.
    private var inlineHUDShowing: Bool {
        coordinator.sneakPeek.show
            && Defaults[.inlineHUD]
            && coordinator.sneakPeek.type != .music
            && coordinator.sneakPeek.type != .battery
            && coordinator.sneakPeek.type != .bluetoothAudio
            && coordinator.sneakPeek.type != .airdropReceive
            && vm.notchState == .closed
    }

    private var currentNotchShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: currentBottomCornerRadius)
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if vm.notchState == .closed && Defaults[.showOnLockScreen] && (vm.isScreenLocked || isUnlockAnimating) {
            chinWidth += 60
        } else if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .bluetoothAudio
            && vm.notchState == .closed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) - 10)
        } else if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .airdropReceive
            && vm.notchState == .closed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) - 10)
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
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
                        : cornerRadiusInsets.closed.bottom
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
                                    topCornerRadius: topCornerRadius,
                                    bottomCornerRadius: currentBottomCornerRadius
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
                                let isFrameSmall = measuredGlassSize.height <= vm.effectiveClosedNotchHeight + 4
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
                        }
                    }
                    .onChange(of: coordinator.hudLimitBounceEvent) { _, newEvent in
                        vm.triggerHUDLimitBounce(rightEdge: newEvent.rightEdge)
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
                        coordinator.currentView = .shelf
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
                } else {
                    // Locked state — show lock icon first, before any other content
                    let hudIsActive = coordinator.sneakPeek.show
                        && coordinator.sneakPeek.type != .music
                        && coordinator.sneakPeek.type != .bluetoothAudio
                        && coordinator.sneakPeek.type != .airdropReceive
                        && vm.notchState == .closed

                    if Defaults[.showOnLockScreen] && (vm.isScreenLocked || isUnlockAnimating) && !hudIsActive {
                        HStack(spacing: 0) {
                            LockNotchOverlay(isLocked: vm.isScreenLocked, isUnlockAnimating: $isUnlockAnimating, host: lockAnimationHost)
                                .allowsHitTesting(false)
                                .padding(.leading, cornerRadiusInsets.closed.bottom - 10)
                            Spacer()
                        }
                        .frame(width: vm.closedNotchSize.width + 50, height: vm.effectiveClosedNotchHeight)
                    } else {
                        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                        {
                            BatteryNotchBanner()
                        } else if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .bluetoothAudio && vm.notchState == .closed {
                            BluetoothHUDView(
                                icon: coordinator.sneakPeek.icon,
                                deviceName: coordinator.sneakPeek.deviceName,
                                batteryFraction: coordinator.sneakPeek.value,
                                isExpanded: $bluetoothHUDExpanded
                            )
                            .environmentObject(vm)
                            .transition(.opacity)
                        } else if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .airdropReceive && vm.notchState == .closed {
                            AirDropReceiveHUD(
                                progress: coordinator.sneakPeek.value,
                                filePath: coordinator.sneakPeek.deviceName,
                                isExpanded: $airdropHUDExpanded
                            )
                            .environmentObject(vm)
                            .transition(.opacity)
                        } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && (coordinator.sneakPeek.type != .bluetoothAudio) && (coordinator.sneakPeek.type != .airdropReceive) && vm.notchState == .closed {
                            InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress, label: coordinator.sneakPeek.deviceName, tintColor: coordinator.sneakPeek.accentColor)
                                .transition(.opacity)
                        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                            MusicLiveActivity(albumArtNamespace: albumArtNamespace)
                                .frame(alignment: .center)
                        } else if vm.notchState == .closed && !TimerManager.shared.allTimers.isEmpty && !TimerManager.shared.isPausedIdle && !vm.hideOnClosed {
                            TimerCompactPill()
                                .frame(width: vm.closedNotchSize.width - 20 + timerCompactPillExtraWidth, height: vm.effectiveClosedNotchHeight, alignment: .center)
                                .transition(.opacity)
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
                        } else {
                            Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                        }
                        
                        if coordinator.sneakPeek.show {
                            if coordinator.sneakPeek.type == .bluetoothAudio && vm.notchState == .closed {
                            } else if coordinator.sneakPeek.type == .airdropReceive && vm.notchState == .closed {
                            } else if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && (coordinator.sneakPeek.type != .bluetoothAudio) && (coordinator.sneakPeek.type != .airdropReceive) && !Defaults[.inlineHUD] && vm.notchState == .closed {
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
                                .padding(.bottom, 10)
                                // Matches the music row's own leading/trailing split just
                                // below — same bottom corner radius (22, see defaultHUDShowing
                                // in currentBottomCornerRadius), so the same padding clears it
                                // without the icon/slider visibly running into the curve.
                                .padding(.leading, 5)
                                .padding(.trailing, 12)
                            }
                            // Old sneak peek music
                            else if coordinator.sneakPeek.type == .music {
                                if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                    HStack(alignment: .center) {
                                        // Zero-width, hidden — reserves exactly the same
                                        // intrinsic height the visible music.note icon used
                                        // to contribute as a real sibling here, so the
                                        // .fixedSize() below still computes the original
                                        // (compact) ideal height for this row instead of
                                        // falling back to GeometryReader's own ambiguous
                                        // ideal size, which drifted taller. Takes no
                                        // horizontal space, so it doesn't push the visible
                                        // (now inline) icon+text away from the leading edge.
                                        Image(systemName: "music.note")
                                            .hidden()
                                            .frame(width: 0)
                                        GeometryReader { geo in
                                            MarqueeText(
                                                .constant(musicManager.songTitle + " • " + musicManager.artistName),
                                                font: .body.weight(.semibold),
                                                textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray,
                                                minDuration: 1,
                                                frameWidth: geo.size.width,
                                                dimmedSubstring: "•",
                                                dimmedColor: Color.gray.opacity(0.6),
                                                scrollSpeed: 34,
                                                leadingIcon: "music.note",
                                                leadingIconColor: Color.gray.opacity(0.6),
                                                centerWhenFits: true,
                                                needsScrollingBinding: $sneakPeekTitleScrolling
                                            )
                                            .conditionalModifier(sneakPeekTitleScrolling) { view in
                                                view.edgeFade(leading: 6)
                                            }
                                        }
                                    }
                                    // Leading kept tighter than trailing — this row's own
                                    // bottom-left corner doesn't curve in as sharply as the
                                    // notch's top corner does, so it can sit closer to the
                                    // edge and give the marquee more room before it needs to
                                    // scroll at all.
                                    .padding(.leading, 5)
                                    .padding(.trailing, 12)
                                    .padding(.bottom, 10)
                                }
                            }
                        }
                    }
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
                        // NotchHomeView applies the stretch per-widget internally,
                        // so each element stays in place relative to its neighbors.
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        // The shelf ("tray") is unreachable in Compact mode — fall
                        // back to the home content instead of ever showing it,
                        // regardless of how currentView got set.
                        if Defaults[.enableCompactUI] {
                            NotchHomeView(albumArtNamespace: albumArtNamespace)
                        } else {
                            ShelfView()
                                .liquidStretch(vm)
                        }
                    }
                }
                // Pin content to the un-stretched target height so the liquid pull only
                // inflates the bezel around it — flexible children like the album art
                // image would otherwise grow into the offered extra height and get
                // clipped by the shape's rounded top corner.
                .frame(maxWidth: .infinity, maxHeight: vm.notchSize.height, alignment: .top)
                // No more width transition between home and shelf — notchSize
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
        if Defaults[.knotchShelf] && vm.notchState == .closed && !Defaults[.enableCompactUI] {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
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

            if Defaults[.enableCompactUI] && coordinator.currentView == .home {
                // Only something to swipe between when both compact views are
                // enabled — otherwise whichever one is on is always shown.
                if Defaults[.compactShowMusicView] && Defaults[.compactShowCalendarView] {
                    hasTriggeredSwipe = true
                    if Defaults[.enableHaptics] { haptics.toggle() }
                    withAnimation(animationSpring) {
                        vm.showingCompactCalendar.toggle()
                        // Snapped to full stretch in the same animation as the
                        // toggle, so the shape's reactivity always lands in sync
                        // with the switch regardless of how light the gesture was.
                        vm.liquidPull = pullClamp
                    }
                }
            } else if Defaults[.swipeToCycleViews] && !TimerManager.shared.isCreatingTimer && !Defaults[.enableCompactUI] {
                let destination: NotchViews = coordinator.currentView == .home ? .shelf : .home
                let destinationEnabled = destination == .home
                    ? Defaults[.showHomeView]
                    : Defaults[.showShelfView]
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
