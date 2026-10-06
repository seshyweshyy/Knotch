//
//  ThumbnailService.swift
//  Knotch
//
//  Created by Alexander on 2025-10-07.
//

import Foundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

actor ThumbnailService {
    static let shared = ThumbnailService()

    // NSCache evicts under memory pressure and caps entry count, unlike the
    // plain dictionary this replaced which grew forever (clearCache existed
    // but nothing ever called it, so every Tray thumbnail stayed resident).
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()
    // NSCache can't enumerate/prefix-match its keys, so track which cache
    // keys belong to a given file path to support clearCache(for:).
    private var keysByPath: [String: Set<String>] = [:]
    private var pendingRequests: [String: Task<NSImage?, Never>] = [:]
    private let thumbnailGenerator = QLThumbnailGenerator.shared

    private init() {}

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let cacheKey = "\(url.path)_\(size.width)x\(size.height)"

        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }

        if let pending = pendingRequests[cacheKey] {
            return await pending.value
        }

        let task = Task<NSImage?, Never> {
            let thumbnail = await generateQuickLookThumbnail(for: url, size: size)
            if let thumbnail = thumbnail {
                cache.setObject(thumbnail, forKey: cacheKey as NSString)
                keysByPath[url.path, default: []].insert(cacheKey)
            }
            pendingRequests[cacheKey] = nil
            return thumbnail
        }

        pendingRequests[cacheKey] = task
        return await task.value
    }

    func clearCache() {
        cache.removeAllObjects()
        keysByPath.removeAll()
    }

    func clearCache(for url: URL) {
        guard let keys = keysByPath.removeValue(forKey: url.path) else { return }
        for key in keys {
            cache.removeObject(forKey: key as NSString)
        }
    }
    
    // MARK: - Private Methods
    
    private func generateQuickLookThumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        
        return await url.accessSecurityScopedResource { scopedURL in
            NSLog("🔐 ThumbnailService: obtaining security scope for \(scopedURL.path)")
            let request = QLThumbnailGenerator.Request(
                fileAt: scopedURL,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            request.iconMode = true

            do {
                let representation = try await thumbnailGenerator.generateBestRepresentation(for: request)
                NSLog("🔍 ThumbnailService: generated thumbnail for \(scopedURL.path)")
                return representation.nsImage
            } catch {
                NSLog("⚠️ ThumbnailService: thumbnail error for \(scopedURL.path): \(error.localizedDescription)")
                return nil
            }
        }
    }
}

// MARK: - Extensions

extension QLThumbnailRepresentation {
    var nsImage: NSImage {
        return NSImage(cgImage: self.cgImage, size: self.cgImage.size)
    }
}

extension CGImage {
    var size: NSSize {
        return NSSize(width: self.width, height: self.height)
    }
}
