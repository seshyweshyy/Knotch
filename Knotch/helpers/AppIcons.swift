//
//  AppIcons.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 16/08/24.
//

import SwiftUI
import AppKit

struct AppIcons {
    
    func getIcon(file path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path)
        else { return nil }
        
        return NSWorkspace.shared.icon(forFile: path)
    }
    
    func getIcon(bundleID: String) -> NSImage? {
        guard let path = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        )?.absoluteString
        else { return nil }
        
        return getIcon(file: path)
    }
    
        /// Easily read Info.plist as a Dictionary from any bundle by accessing .infoDictionary on Bundle
    func bundle(forBundleID: String) -> Bundle? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: forBundleID)
        else { return nil }
        
        return Bundle(url: url)
    }
    
}

// NSWorkspace icon lookups are an IPC round-trip to launchservicesd, and
// AppIcon(for:) gets called from view bodies that re-render far more often
// than the resolved icon actually changes (e.g. every track-change tick in
// NotchHomeView). Cache by bundle ID so repeat lookups are instant.
private final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func icon(for bundleID: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[bundleID] {
            return cached
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache[bundleID] = icon
        return icon
    }
}

func AppIcon(for bundleID: String) -> Image {
    if let cachedIcon = AppIconCache.shared.icon(for: bundleID) {
        return Image(nsImage: cachedIcon)
    }

    return Image(nsImage: NSWorkspace.shared.icon(for: .applicationBundle))
}


// MARK: - No-artwork placeholder

/// Drawn once and reused everywhere the album art has nothing real to show —
/// no track loaded, or a track with no artwork of its own — instead of
/// blowing up the source app's icon or a generic system symbol. A light grey
/// music note on a translucent grey square, filling the same square frame
/// every real album art image fills, so it picks up each view's own corner
/// rounding for free instead of needing its own.
private func makeNoArtworkPlaceholderImage(size: CGFloat = 512) -> NSImage {
    let canvasSize = NSSize(width: size, height: size)
    let backgroundColor = NSColor(white: 0.18, alpha: 0.5)

    guard
        let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: "No Artwork"),
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .medium)
        )
    else {
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        backgroundColor.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()
        image.unlockFocus()
        return image
    }

    // Template images aren't tinted by a plain draw(at:) call — paint the
    // desired color into the symbol's own alpha mask first.
    configured.isTemplate = true
    let tintedSymbol = configured.copy() as! NSImage
    tintedSymbol.lockFocus()
    NSColor(white: 0.5, alpha: 1.0).set()
    NSRect(origin: .zero, size: tintedSymbol.size).fill(using: .sourceAtop)
    tintedSymbol.unlockFocus()

    let image = NSImage(size: canvasSize)
    image.lockFocus()
    backgroundColor.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    let symbolSize = tintedSymbol.size
    let origin = NSPoint(x: (canvasSize.width - symbolSize.width) / 2, y: (canvasSize.height - symbolSize.height) / 2)
    tintedSymbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    image.unlockFocus()

    return image
}

let noArtworkPlaceholderImage: NSImage = makeNoArtworkPlaceholderImage()

