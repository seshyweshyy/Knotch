import AppKit
import ImageIO
import SwiftUI

/// A bounded thumbnail shared by all appearance cards. Never decode a full
/// desktop-sized image separately for each small settings preview.
@MainActor
final class SettingsPreviewWallpaper: ObservableObject {
    static let shared = SettingsPreviewWallpaper()
    @Published private(set) var image: NSImage?
    private var loadedURL: URL?

    func refresh() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              loadedURL != url else { return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            image = nil
            return
        }
        loadedURL = url
        image = NSImage(cgImage: thumbnail, size: .zero)
    }
}
