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

// MARK: - Detecting app-icon artwork from browsers

// Downsample to a small grayscale grid so two renders of the same image compare
// as near-identical even after MediaRemote's own resizing/recompression. Drawn
// through CGContext directly (rather than NSGraphicsContext + NSBitmapImageRep)
// since that combination can silently fail to produce a usable context on some
// image/color-space inputs, which would make the whole check a silent no-op.
private func grayscaleFingerprint(of image: NSImage, background: CGFloat, gridSize: Int = 16) -> [UInt8]? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    guard let context = CGContext(
        data: nil,
        width: gridSize,
        height: gridSize,
        bitsPerComponent: 8,
        bytesPerRow: gridSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let targetRect = CGRect(x: 0, y: 0, width: gridSize, height: gridSize)
    context.setFillColor(red: background, green: background, blue: background, alpha: 1)
    context.fill(targetRect)
    context.draw(cgImage, in: targetRect)

    guard let data = context.data else { return nil }
    let buffer = data.bindMemory(to: UInt8.self, capacity: gridSize * gridSize * 4)
    var fingerprint = [UInt8](repeating: 0, count: gridSize * gridSize)
    for i in 0..<(gridSize * gridSize) {
        let offset = i * 4
        let gray = (Int(buffer[offset]) + Int(buffer[offset + 1]) + Int(buffer[offset + 2])) / 3
        fingerprint[i] = UInt8(gray)
    }
    return fingerprint
}

// Pearson correlation instead of raw pixel difference — it's invariant to a flat
// brightness/contrast offset between the two renders (e.g. MediaRemote flattening
// the icon's transparent background onto black while our own render uses white),
// so it still recognizes "same icon, different backdrop" as a strong match.
private func pearsonCorrelation(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    let n = Double(a.count)
    let meanA = a.reduce(0.0) { $0 + Double($1) } / n
    let meanB = b.reduce(0.0) { $0 + Double($1) } / n
    var numerator = 0.0, denomA = 0.0, denomB = 0.0
    for i in 0..<a.count {
        let da = Double(a[i]) - meanA
        let db = Double(b[i]) - meanB
        numerator += da * db
        denomA += da * da
        denomB += db * db
    }
    guard denomA > 0, denomB > 0 else { return -1 }
    return numerator / (denomA * denomB).squareRoot()
}

private final class AppIconFingerprintCache {
    static let shared = AppIconFingerprintCache()
    // Two renders per bundle ID — white- and black-backed — since we don't know
    // which backdrop MediaRemote flattened its substituted icon onto.
    private var cache: [String: [[UInt8]]] = [:]
    private let lock = NSLock()

    func fingerprints(for bundleID: String) -> [[UInt8]]? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[bundleID] {
            return cached
        }
        guard let icon = AppIconCache.shared.icon(for: bundleID) else { return nil }
        let fingerprints = [
            grayscaleFingerprint(of: icon, background: 1),
            grayscaleFingerprint(of: icon, background: 0),
        ].compactMap { $0 }
        guard !fingerprints.isEmpty else { return nil }
        cache[bundleID] = fingerprints
        return fingerprints
    }
}

/// True when `artwork` is close enough to `bundleID`'s own app icon that it's almost
/// certainly the generic icon MediaRemote substitutes for browser tabs with no real
/// page artwork (see the comment on `MusicManager.browserBundleIdentifiers`), rather
/// than genuine track/video art that just happens to look similar.
func isLikelyBrowserAppIconArtwork(_ artwork: NSImage, forBundleIdentifier bundleID: String) -> Bool {
    guard
        let iconFingerprints = AppIconFingerprintCache.shared.fingerprints(for: bundleID),
        let artworkFingerprint = grayscaleFingerprint(of: artwork, background: 1)
    else { return false }
    let bestCorrelation = iconFingerprints
        .map { pearsonCorrelation($0, artworkFingerprint) }
        .max() ?? -1
    return bestCorrelation > 0.6
}

