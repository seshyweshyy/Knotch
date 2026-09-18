//
//  sizeMatters.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let timerCompactPillExtraWidth: CGFloat = 125

let shadowPadding: CGFloat = 20

// Max extra height the notch can stretch to when pulled during the
// swipe-down tab-switch gesture (clamp * height factor in ContentView).
let liquidPullMaxStretch: CGFloat = 30

// How far a drag can push liquidPull/liquidPullHorizontal before it clamps.
let liquidPullClamp: CGFloat = 70

// Bouncy release used everywhere the liquid pull snaps back to zero.
let liquidReleaseSpring = Animation.spring(response: 0.45, dampingFraction: 0.55, blendDuration: 0)

// Drives the open transition. Slightly underdamped for a subtle iOS-style
// overshoot (shape grows a touch past its resting size, then settles back)
// — compact mode's content reveal rides this same spring for its own
// scale/blur, so keeping it a single shared spring is what keeps the two in
// sync.
let notchOpenSpring = Animation.spring(response: 0.40, dampingFraction: 0.625, blendDuration: 0)

// Release used when the HUD edge overshoot (volume/brightness hitting 0%/100%)
// snaps back to zero. Kept independent from liquidReleaseSpring so it can be
// tuned without affecting the gesture-driven liquid pull.
let hudLimitBounceSpring = Animation.spring(response: 0.8, dampingFraction: 0.95, blendDuration: 0)

// No overshoot on close — critically damped regardless of the open spring.
let notchCloseSpring = Animation.spring(response: 0.35, dampingFraction: 1.0, blendDuration: 0)

// Drives the closed-notch row's collapse-to-notch/expand-back-out choreography
// (ClosedNotchRowContent's rowMorph) whenever a HUD and a live activity (music/
// timer) swap places in the same slot. Slowed down from an initial 0.28/0.18
// pairing that read as too quick/snappy.
let rowMorphSpring = Animation.spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0)

// Only volume/brightness use this — a quicker expand-out specifically for
// those two, layered on top of rowMorphSpring's normal timing for everything
// else (including their own collapse-in, and every other HUD/live-activity
// swap).
let rowMorphFastSpring = Animation.spring(response: 0.26, dampingFraction: 0.82, blendDuration: 0)

// Row's own collapse when the notch opens (not a family swap) — quicker
// than rowMorphSpring since the open panel is already fading in on top.
let rowFadeOutOnOpenSpring = Animation.spring(response: 0.1, dampingFraction: 1.0, blendDuration: 0)

// How long to wait after starting the collapse (rowMorph -> 0) before actually
// swapping displayedRowFamily's content — timed to land once the collapsing
// content is already scaled/blurred down to effectively invisible, so the
// swap itself is imperceptible. Shorter than rowMorphSpring's full response
// since the content is unreadable well before the spring fully settles.
let rowMorphSwapDelay: TimeInterval = 0.28

// Drives the live-activity "squish and blur" pop in/out (see
// AnyTransition.liveActivityPop in NotchTransition.swift). Used for the
// compact drag-and-drop overlay's own appearance/disappearance.
let liveActivityPopSpring = Animation.spring(response: 0.47, dampingFraction: 0.77)

let openNotchSize: CGSize = .init(width: 640, height: 190)
// Add a wider size specifically for the home view
let openNotchHomeSize: CGSize = .init(width: 680, height: 190)

// windowSize must be wide enough for the widest possible home layout
let windowSize: CGSize = .init(
    width: WidgetWidth.music + WidgetWidth.calendar + WidgetWidth.camera
           + WidgetWidth.spacing * 2 + WidgetWidth.dividerWidth + WidgetWidth.horizontalPad + 40,
    height: openNotchHomeSize.height + shadowPadding + liquidPullMaxStretch
)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 39), closed: (top: 6, bottom: 14))
let compactCornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 35, bottom: 40), closed: cornerRadiusInsets.closed)

// Min horizontal padding for compact pages to clear the shape's rounded
// corners (35pt radius) — the old 20pt was less than that, so content near
// either edge got clipped regardless of compactOpenNotchSize's width.
let compactContentSafeInset: CGFloat = compactCornerRadiusInsets.opened.top + 15

// Fixed panel size for Compact UI mode, unlike the standard home view.
// User-set at 400x170 after earlier 350/380 attempts — keep as-is.
let compactOpenNotchSize: CGSize = .init(width: 400, height: 170)

// Narrower Compact mode width for the free-floating Dynamic Island
// appearance — 400pt (tuned to comfortably clear the physical notch's own
// footprint) reads as oversized once compact mode isn't hugging a real
// screen-edge cutout anymore.
let compactIslandOpenNotchWidth: CGFloat = 340

// A little taller than the physical-notch default — gives
// CompactMusicPlayerView's own pullUp reservation (the room its album art
// rises into above the fixed-height content box) more headroom, since the
// island appearance pushes that content down further to clear the plain
// convex top corners. compactContentHeight itself (the page content's own
// fixed budget) is untouched — this only grows the slack above it.
let compactIslandOpenNotchHeight: CGFloat = 172

// Single source of truth for Compact mode's current target size — every
// compact page (Music/Calendar/Tray/Converter) and KnotchViewModel's own
// computedHomeSize all read through this, so the panel and every page's
// internal layout stay pinned to the exact same size.
func compactPanelWidth(isIsland: Bool) -> CGFloat {
    isIsland ? compactIslandOpenNotchWidth : compactOpenNotchSize.width
}

func compactPanelHeight(isIsland: Bool) -> CGFloat {
    isIsland ? compactIslandOpenNotchHeight : compactOpenNotchSize.height
}

// Shared content height across compact pages, so switching between them
// never changes the panel size. Raised in step with compactOpenNotchSize's
// own height bump, so pages actually use the box's extra room.
let compactContentHeight: CGFloat = 140

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 18.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

// The physical notch's own default closed-pill width (185, further down)
// exists because that pill has to be at least as wide as the real camera
// housing to visually hide behind it — Dynamic Island appearance has no
// such cutout to hide behind, so its own default is its own, separate,
// deliberately narrower value rather than a scaled-down copy of the
// physical one.
let islandClosedNotchWidth: CGFloat = 85

// Whether `screenUUID` (or the main screen, if nil) should render the
// floating "Dynamic Island" pill — uniform convex corners on all four
// sides, detached from the screen's top edge — instead of the physical-
// notch silhouette (concave top corners flush with the top edge).
// Automatic on any display without a real hardware notch (external
// monitors, non-notched MacBooks); forceSimulatedNotch opts a display back
// into the physical-notch look, and debugForceDynamicIslandAppearance
// previews the island look on a display that does have a real notch —
// checked first so it always wins for local testing.
@MainActor func usesDynamicIslandAppearance(
    screenUUID: String?,
    forceSimulatedNotch: Bool,
    debugForceDynamicIsland: Bool
) -> Bool {
    if debugForceDynamicIsland { return true }
    if forceSimulatedNotch { return false }

    var selectedScreen = NSScreen.main
    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    return (selectedScreen?.safeAreaInsets.top ?? 0) <= 0
}

// Convenience overload for call sites that don't need to establish a
// SwiftUI observation dependency on the two Defaults themselves (they just
// want the current answer). Views that gate their `body` on this should
// instead read both Defaults via @Default and call the explicit overload
// above, the same way ContentView already does for other Defaults-gated
// layout decisions — a raw Defaults[...] read here establishes no
// dependency, so a Settings toggle wouldn't invalidate their body.
@MainActor func usesDynamicIslandAppearance(screenUUID: String? = nil) -> Bool {
    usesDynamicIslandAppearance(
        screenUUID: screenUUID,
        forceSimulatedNotch: Defaults[.forceSimulatedNotch],
        debugForceDynamicIsland: Defaults[.debugForceDynamicIslandAppearance]
    )
}

// Shared outer silhouette for the notch/island pill. Dynamic Island
// appearance always uses a single radius on all four corners (a plain
// convex rounded rect) regardless of topCornerRadius/bottomCornerRadius
// individually differing — the physical notch's concave top corners are
// what make top/bottom need separate radii in the first place, and this
// shape doesn't have those.
// .circular, not .continuous — .continuous ("squircle") corners use a
// different curvature than a true circular arc, and even at the maximum
// possible radius (exactly half the shorter edge) that curve still reads as
// visibly flatter than a genuine semicircular cap, which is specifically
// what a pill/capsule needs at its rounded ends. .circular is the one that
// actually converges to a true semicircle there. Radius is still clamped
// ourselves (see the struct's own history) rather than trusting
// RoundedRectangle's automatic clamp.
struct IslandPillShape: Shape {
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let resolvedRadius = min(cornerRadius, min(rect.width, rect.height) / 2)
        return Path(roundedRect: rect, cornerRadius: resolvedRadius, style: .circular)
    }
}

// Always RoundedRectangle for island, never Capsule — even gated to only
// the idle/inline states, switching the actual *shape type* produced a
// visible snap-to-sharp-corners glitch right at the moment it switched
// to/from Capsule, because AnyShape can't smoothly morph between two
// different underlying Shape types the way it can interpolate a single
// RoundedRectangle's own animatable cornerRadius. A true pill is instead
// produced by feeding this a radius equal to half the current height (see
// ContentView's currentBottomCornerRadius) — RoundedRectangle already
// clamps its own radius to half of whichever edge is shorter, so that
// still renders as a true, fully-rounded capsule, just via a plain,
// continuously animatable number instead of a type switch.
func notchOuterShape(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat, isIsland: Bool) -> AnyShape {
    if isIsland {
        return AnyShape(IslandPillShape(cornerRadius: bottomCornerRadius))
    }
    return AnyShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch — real hardware
        // notch dimensions take priority, so a debug-forced island preview
        // on an actually-notched Mac still narrows to the island width below
        // rather than reporting the real cutout's width.
        let isIslandWidth = usesDynamicIslandAppearance(
            screenUUID: screenUUID,
            forceSimulatedNotch: Defaults[.forceSimulatedNotch],
            debugForceDynamicIsland: Defaults[.debugForceDynamicIslandAppearance]
        )
        if !isIslandWidth,
           let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        } else if isIslandWidth {
            notchWidth = islandClosedNotchWidth
        }

        // Check if the Mac has a notch (or the user forced the notch look
        // back on for a display that doesn't) — the debug island override
        // is deliberately not consulted here, so forcing the island
        // appearance for testing doesn't also swap which height setting is
        // in effect.
        if !usesDynamicIslandAppearance(screenUUID: screenUUID, forceSimulatedNotch: Defaults[.forceSimulatedNotch], debugForceDynamicIsland: false) {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : notchHeight
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                // 2pt shorter than the menu bar itself, not an exact match —
                // paired with dynamicIslandTopInset's own 1pt gap from the
                // screen's top edge, so the floating pill reads as sitting
                // just inside the menu bar strip rather than exactly filling it.
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY - 2
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}

/// Computes the open notch width for the home view based on which widgets are active.
enum WidgetWidth {
    static let music: CGFloat    = 380
    static let calendar: CGFloat = 220
    static let camera: CGFloat   = 142
    static let calendarWithCam: CGFloat = 180
    static let spacing: CGFloat  = 12
    static let dividerWidth: CGFloat = 1
    static let horizontalPad: CGFloat = 60  // ContentView's horizontal padding * 2
    static let timerSlider: CGFloat = 440   // notch width while the timer ruler is showing
}

func computedOpenNotchHomeWidth(
    showMusic: Bool,
    showCalendar: Bool,
    showMirror: Bool,
    cameraExpanded: Bool,
    cameraAvailable: Bool
) -> CGFloat {
    let showCam = showMirror && cameraAvailable && cameraExpanded
    let showCal = showCalendar

    var widths: [CGFloat] = []
    if showMusic    { widths.append(WidgetWidth.music) }
    if showCal      { widths.append(showCam ? WidgetWidth.calendarWithCam : WidgetWidth.calendar) }
    if showCam      { widths.append(WidgetWidth.camera) }

    guard !widths.isEmpty else { return openNotchSize.width }

    var dividerCount = 0
    if showMusic && showCal { dividerCount += 1 }
    if showCam && (showMusic || showCal) { dividerCount += 1 }
    let dividers: CGFloat = WidgetWidth.dividerWidth * CGFloat(dividerCount)
    let spacingTotal = WidgetWidth.spacing * CGFloat(widths.count - 1)
    let total = widths.reduce(0, +) + spacingTotal + dividers + WidgetWidth.horizontalPad

    return max(total, 300) // minimum sane width
}
