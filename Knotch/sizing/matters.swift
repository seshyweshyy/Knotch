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

let shadowPadding: CGFloat = 20

let openNotchSize: CGSize = .init(width: 640, height: 190)
// Add a wider size specifically for the home view
let openNotchHomeSize: CGSize = .init(width: 680, height: 190)

// windowSize must be wide enough for the widest possible home layout
let windowSize: CGSize = .init(
    width: WidgetWidth.music + WidgetWidth.calendar + WidgetWidth.camera
           + WidgetWidth.spacing * 2 + WidgetWidth.dividerWidth + WidgetWidth.horizontalPad + 40,
    height: openNotchHomeSize.height + shadowPadding
)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 39), closed: (top: 6, bottom: 14))

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
    static let camera: CGFloat   = 100
    static let calendarWithCam: CGFloat = 180
    static let spacing: CGFloat  = 12
    static let dividerWidth: CGFloat = 1
    static let horizontalPad: CGFloat = 60  // ContentView's horizontal padding * 2
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

    let dividers: CGFloat = showMusic && (showCal || showCam) ? WidgetWidth.dividerWidth : 0
    let spacingTotal = WidgetWidth.spacing * CGFloat(widths.count - 1)
    let total = widths.reduce(0, +) + spacingTotal + dividers + WidgetWidth.horizontalPad

    return max(total, 300) // minimum sane width
}
