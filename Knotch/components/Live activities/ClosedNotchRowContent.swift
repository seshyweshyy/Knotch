//
//  ClosedNotchRowContent.swift
//  Knotch
//

import Defaults
import SwiftUI

/// Whichever single thing currently owns the closed-notch "row 1" slot.
/// `ContentView` tracks a *desired* family (from live coordinator/manager
/// state) and a *displayed* family (what's actually rendered right now) —
/// the two are allowed to briefly disagree while `rowMorph` collapses the
/// old family away before swapping to the new one. See ContentView's
/// `desiredRowFamily`/`displayedRowFamily`/`rowMorph`.
enum ClosedRowFamily: Equatable {
    case none
    case hud
    case music
    case timer
    // Locked, with no HUD active — just the lock icon. A HUD triggering while
    // locked switches straight to `.hud` (see ContentView's desiredRowFamily),
    // fully replacing this the same way any other family swap does: the lock
    // icon collapses in, then the HUD expands out — and back, once the HUD
    // ends and this becomes the desired family again.
    case lock
    // BatteryNotchBanner (low/full battery, or the low-power-mode toggle
    // message) — same treatment as everything else: whatever was showing
    // collapses in, the battery banner expands out, then collapses back to
    // let the original activity expand back out once it ends.
    case battery
}

/// The width a given closed-row family's content actually needs once fully
/// at rest (rowMorph == 1) — derived from each view's own real internal
/// layout (icon/gap/trailing-block widths for the compact pills, the known
/// flat expanded-card widths for Bluetooth/AirDrop, etc.), not a guess.
/// Shared by ContentView's `computedChinWidth` (the invisible hit-rect) and
/// `ClosedNotchRowContent`'s own visible frame, so the two can't drift apart,
/// and so the collapse always has a real, continuous width to blend from/to
/// instead of snapping straight from one family's width to another's.
func restingRowWidth(
    for family: ClosedRowFamily,
    sneakPeekType: SneakContentType,
    closedNotchWidth: CGFloat,
    effectiveClosedNotchHeight: CGFloat,
    bluetoothHUDExpanded: Bool,
    airdropHUDExpanded: Bool,
    inlineHUD: Bool
) -> CGFloat {
    switch family {
    case .none:
        // The true collapse floor — matches the -20 every compact pill here
        // already bakes into its own center gap (BluetoothHUDView/
        // AirDropReceiveHUD/InlineHUD/TimerCompactPill), since closedNotchWidth
        // itself reads a bit wider than the notch actually is once that's
        // accounted for.
        return closedNotchWidth - 20
    case .lock:
        // Matches the original fixed lock-only pill width.
        return closedNotchWidth + 50
    case .hud:
        switch sneakPeekType {
        case .bluetoothAudio:
            // BluetoothHUDView.expandedWidth, else its own compact HStack:
            // leading icon block (h-4+10) + center gap (closedNotchWidth-20)
            // + trailing battery block (30) = closedNotchWidth + h + 16.
            return bluetoothHUDExpanded ? 280 : closedNotchWidth + effectiveClosedNotchHeight + 16
        case .airdropReceive:
            // AirDropReceiveHUD.expandedWidth, else the same inline-pill
            // layout Bluetooth's compact form uses.
            return airdropHUDExpanded ? 300 : closedNotchWidth + effectiveClosedNotchHeight + 16
        case .mic:
            // Just an icon + short "muted"/"unmuted" label — no slider.
            return inlineHUD ? closedNotchWidth + 44 : closedNotchWidth + 140
        case .focusMode:
            // No slider either, but the focus mode's own name (label) can run
            // longer than "muted"/"unmuted" ("Do Not Disturb", etc.), so this
            // wants more trailing room than mic gets.
            return inlineHUD ? closedNotchWidth + 58 : closedNotchWidth + 155
        default:
            // Volume/brightness/backlight all carry a DraggableProgressBar
            // plus a percentage label — want real breathing room on the
            // trailing end so the slider/label don't crowd the pill's edge.
            return inlineHUD ? closedNotchWidth + 170 : closedNotchWidth + 235
        }
    case .music:
        // Matches MusicLiveActivity's own three-part HStack (album art +
        // center gap + visualizer) plus its default inter-item spacing —
        // trimmed down after this ran noticeably wider than the actual
        // content, leaving dead space on both sides (MusicLiveActivity
        // doesn't stretch to fill, so any excess here just centers as gaps).
        return closedNotchWidth + 2 * max(0, effectiveClosedNotchHeight - 12) + 8
    case .timer:
        return closedNotchWidth - 20 + timerCompactPillExtraWidth
    case .battery:
        // Matches BatteryNotchBanner's own two forms: the low/full-battery
        // takeover card is a flat 280 (bannerWidth), while the low-power-mode
        // toggle message's slim pill is status-text(110) + gap(closedNotchWidth+40)
        // + battery-icon(76) = closedNotchWidth + 226.
        let batteryModel = BatteryStatusViewModel.shared
        let isStandardBanner = (batteryModel.levelBattery <= 20 && !batteryModel.isCharging && !batteryModel.isPluggedIn)
            || (batteryModel.levelBattery == 100 && (batteryModel.isCharging || batteryModel.isPluggedIn))
        return isStandardBanner ? 280 : closedNotchWidth + 226
    }
}

/// Renders whichever `ClosedRowFamily` is currently displayed, using exactly
/// the same child views/bindings the old inline if/else-if chain in
/// `ContentView.NotchLayout()` used — nothing about Bluetooth/AirDrop/
/// InlineHUD/SystemEventIndicatorModifier/MusicLiveActivity/TimerCompactPill
/// themselves changes here, only where they're called from.
///
/// The whole thing is wrapped in an Alcove-style collapse/expand transform
/// driven by `morph` (1 = fully resting, 0 = collapsed into the bare notch):
/// an anisotropic scale (squishes horizontally more than vertically, tracking
/// the notch's own width narrowing — see ContentView's shape-radius blend),
/// continuous blur peaking at the collapsed midpoint, and a matching opacity
/// fade — so a family swap reads as squeezing together into the notch and
/// blurring through the middle of the motion, not just crossfading in place.
struct ClosedNotchRowContent: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @EnvironmentObject var lockAnimationHost: LockAnimationHost

    let family: ClosedRowFamily
    let morph: CGFloat
    @Binding var isUnlockAnimating: Bool
    @Binding var bluetoothHUDExpanded: Bool
    @Binding var airdropHUDExpanded: Bool
    @Binding var sneakPeekTitleScrolling: Bool
    let albumArtNamespace: Namespace.ID
    @Binding var isHovering: Bool
    @Binding var gestureProgress: CGFloat

    // The bare notch's own width — the true floor this row's content
    // collapses to at morph == 0. Matches the -20 every other compact pill
    // here already uses for its own center gap (BluetoothHUDView/
    // AirDropReceiveHUD/InlineHUD/TimerCompactPill all size their gap to
    // closedNotchSize.width - 20, and the original plain-closed fallback
    // this whole system replaced used the same width) — closedNotchSize.width
    // itself runs a bit wider than the notch actually reads as once the
    // corner insets/margins every one of those already accounts for are
    // factored in.
    private var bareWidth: CGFloat { vm.closedNotchSize.width - 20 }

    // What `family`'s content actually needs at full rest (morph == 1). Fed
    // the raw closedNotchSize.width (not bareWidth) — every non-.none formula
    // in restingRowWidth is calibrated against that same raw value the actual
    // views (BluetoothHUDView etc.) use for their own internal gap sizing.
    private var restingWidth: CGFloat {
        restingRowWidth(
            for: family,
            sneakPeekType: coordinator.sneakPeek.type,
            closedNotchWidth: vm.closedNotchSize.width,
            effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight,
            bluetoothHUDExpanded: bluetoothHUDExpanded,
            airdropHUDExpanded: airdropHUDExpanded,
            inlineHUD: Defaults[.inlineHUD]
        )
    }

    // Continuously blends from restingWidth down to bareWidth as morph goes
    // 1 -> 0 — this is the row's *actual* layout width (not just a visual
    // scaleEffect), so the collapse genuinely narrows down to the real notch
    // width instead of snapping straight from one family's width to another's
    // hidden behind the blur/fade.
    private var rowWidth: CGFloat {
        bareWidth + (restingWidth - bareWidth) * morph
    }

    var body: some View {
        content
            // Laid out at its natural resting size first — minHeight (not a
            // fixed height) guarantees at least the notch's own height even
            // for content that reports zero (EmptyView for .none — the old
            // plain fallback always had an explicit height, this didn't),
            // while still letting genuinely taller content (Bluetooth/AirDrop's
            // expanded card, BatteryNotchBanner's standard banner) grow past
            // it. Without a real height, the whole notch collapsed to a
            // hairline with nothing left to hover/tap to reopen it.
            .frame(width: restingWidth, alignment: .center)
            .frame(minHeight: vm.effectiveClosedNotchHeight)
            // ...then visually squished to match the currently-interpolated
            // rowWidth, so content compresses together with the shrinking
            // frame instead of just getting clipped by it. The y squish is
            // deliberately subtle — height doesn't actually change between
            // families, this is only selling the "squeezing in" motion.
            .scaleEffect(
                x: restingWidth > 0 ? rowWidth / restingWidth : 1,
                y: 0.88 + 0.12 * morph,
                anchor: .center
            )
            // ...and the reported/layout size matches the visually-squished
            // size, so .fixedSize() and the shared background box actually
            // follow rowWidth too, not restingWidth.
            .frame(width: rowWidth, alignment: .center)
            .blur(radius: (1 - morph) * 6)
            .opacity(morph)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .none:
            // A concrete clear Rectangle with a hard (not min) height/width,
            // matching the original plain fallback exactly — EmptyView here
            // reports zero intrinsic size on both axes, and relying on
            // body()'s minHeight alone to correct that turned out not to be
            // enough to keep the whole notch from collapsing to a hairline
            // with nothing left to hover/tap to reopen it.
            Rectangle()
                .fill(.clear)
                .frame(width: bareWidth, height: vm.effectiveClosedNotchHeight)
        case .lock:
            HStack(spacing: 0) {
                lockIcon
                Spacer(minLength: 0)
            }
            .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        case .hud:
            hudContent
        case .music:
            musicContent
        case .timer:
            TimerCompactPill()
                .frame(
                    width: vm.closedNotchSize.width - 20 + timerCompactPillExtraWidth,
                    height: vm.effectiveClosedNotchHeight,
                    alignment: .center
                )
                .transition(.opacity)
        case .battery:
            BatteryNotchBanner()
                .transition(.opacity)
        }
    }

    private var lockIcon: some View {
        LockNotchOverlay(isLocked: vm.isScreenLocked, isUnlockAnimating: $isUnlockAnimating, host: lockAnimationHost)
            .allowsHitTesting(false)
            .padding(.leading, cornerRadiusInsets.closed.bottom - 10)
    }

    @ViewBuilder
    private var hudContent: some View {
        if coordinator.sneakPeek.type == .bluetoothAudio {
            BluetoothHUDView(
                icon: coordinator.sneakPeek.icon,
                deviceName: coordinator.sneakPeek.deviceName,
                batteryFraction: coordinator.sneakPeek.value,
                isExpanded: $bluetoothHUDExpanded
            )
            .environmentObject(vm)
            .transition(.opacity)
        } else if coordinator.sneakPeek.type == .airdropReceive {
            AirDropReceiveHUD(
                progress: coordinator.sneakPeek.value,
                filePath: coordinator.sneakPeek.deviceName,
                isExpanded: $airdropHUDExpanded
            )
            .environmentObject(vm)
            .transition(.opacity)
        } else if Defaults[.inlineHUD] {
            InlineHUD(
                type: $coordinator.sneakPeek.type,
                value: $coordinator.sneakPeek.value,
                icon: $coordinator.sneakPeek.icon,
                hoverAnimation: $isHovering,
                gestureProgress: $gestureProgress,
                label: coordinator.sneakPeek.deviceName,
                tintColor: coordinator.sneakPeek.accentColor
            )
            .transition(.opacity)
        } else {
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
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var musicContent: some View {
        VStack(alignment: .leading) {
            MusicLiveActivity(albumArtNamespace: albumArtNamespace)
                .frame(alignment: .center)

            // Old-style sneak peek: a title/artist marquee reveal layered
            // below the persistent music bar, distinct from the .hud family
            // swap above (sneakPeek.type == .music is excluded from .hud).
            if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music
                && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard
            {
                HStack(alignment: .center) {
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
                // Matches MusicLiveActivity's own horizontal padding during
                // this same active-reveal state (see its `.padding(.horizontal, ...
                // ? 6 : 0)`) so the marquee's edges land exactly under the
                // album art/visualizer above it, instead of drifting off to
                // one side under its own, different padding. Pinned to the
                // row's own current width rather than left to resolve
                // implicitly through the GeometryReader/VStack flex above —
                // that let it stretch wider than the live activity row and
                // run past where the text actually needs to truncate/scroll.
                // The extra padding on top of that matched 6pt accounts for
                // the album art/visualizer's own further inset within that
                // padding (they don't sit flush against it either), so the
                // text doesn't start/end right at their edges — bumped again,
                // 8 still wasn't enough clearance.
                .frame(width: restingWidth, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
    }
}
