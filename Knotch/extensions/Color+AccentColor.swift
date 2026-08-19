//
//  Color+AccentColor.swift
//  Knotch
//
//  Created by Alexander on 2025-10-24.
//

import SwiftUI
import Defaults

extension Color {
    static var effectiveAccent: Color {
        if Defaults[.useCustomAccentColor],
           let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return Color(nsColor: nsColor)
        }
        return .accentColor
    }
    
    /// Returns a darker version of the accent color suitable for backgrounds
    static var effectiveAccentBackground: Color {
        if Defaults[.useCustomAccentColor],
           let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return Color(nsColor: nsColor.withSystemEffect(.disabled))
        }
        return Color.effectiveAccent.opacity(0.25)
    }

    /// Icon tint for media transport buttons other than play/pause and
    /// previous/next (shuffle, repeat, volume, favorite, audio output, etc.)
    /// — dimmer than .primary so those buttons read as secondary controls.
    static let mediaControlSecondary = Color.white.opacity(0.7)

    /// Icon tint for a disabled media control button, replacing .primary/
    /// avgColor entirely rather than just dimming it via opacity — dimmer
    /// still than mediaControlSecondary.
    static let mediaControlDisabled = Color.white.opacity(0.35)
}

extension NSColor {
    static var effectiveAccent: NSColor {
        if Defaults[.useCustomAccentColor],
           let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return nsColor
        }
        return NSColor.controlAccentColor
    }
    
    /// Returns a darker version of the accent color as NSColor suitable for backgrounds
    static var effectiveAccentBackground: NSColor {
        if Defaults[.useCustomAccentColor],
           let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return nsColor.withSystemEffect(.disabled)
        }
        return NSColor.controlAccentColor.withAlphaComponent(0.25)
    }
}
