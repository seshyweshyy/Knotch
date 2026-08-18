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

// Drives the open transition. Critically damped (no overshoot) — compact
// mode's content reveal rides this same spring for its own scale/blur, so
// an overshoot here would show as a visible mismatch between the two.
let notchOpenSpring = Animation.spring(response: 0.40, dampingFraction: 1.0, blendDuration: 0)

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

// Shared content height across compact pages, so switching between them
// never changes the panel size. Raised in step with compactOpenNotchSize's
// own height bump, so pages actually use the box's extra room.
let compactContentHeight: CGFloat = 140

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 18.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
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
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
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
