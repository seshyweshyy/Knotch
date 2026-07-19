//
//  QuickShareService.swift
//  Knotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Dynamic representation of a sharing provider discovered at runtime
struct QuickShareProvider: Identifiable, Hashable, Sendable {
    var id: String
    var imageData: Data?
    var supportsRawText: Bool
}

class QuickShareService: ObservableObject {
    static let shared = QuickShareService()
    
    @Published var availableProviders: [QuickShareProvider] = []
    @Published var isPickerOpen = false
    private var cachedServices: [String: NSSharingService] = [:]
    // Hold security-scoped URLs during sharing
    private var sharingAccessingURLs: [URL] = []
    private var lifecycleDelegate: SharingLifecycleDelegate?
   
    init() {
        Task {
            await discoverAvailableProviders()
        }
    }
    
    // MARK: - Provider Discovery
    
    @MainActor
    func discoverAvailableProviders() async {
        let finder = ShareServiceFinder()

        // Use simple test items without creating actual temp files
        // This avoids issues with the Share Sheet retaining references to deleted files
        let testItems: [Any] = [
            URL(string:"http://example.com") ?? URL(fileURLWithPath: "/"),
            "Test Text" as NSString
        ]

        let services = await finder.findApplicableServices(for: testItems)

        var providers: [QuickShareProvider] = []
        
        let excludedProviders: Set<String> = ["Simulator"]

        for svc in services {
            let title = svc.title
            guard !excludedProviders.contains(title) else { continue }
            let imgData: Data? = {
                if title == "AirDrop" {
                    // The AirDrop NSSharingService returned by the picker enumeration
                    // sometimes has an uninitialized (zero-size) .image until the
                    // picker actually displays it. Constructing a fresh instance by
                    // name guarantees a fully-loaded icon.
                    let airdropImage = NSSharingService(named: .sendViaAirDrop)?.image ?? svc.image
                    return Self.resizedIconData(from: airdropImage)
                }
                // Try to find the app by its display/bundle name and use its real icon
                let allApps = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
                    + FileManager.default.urls(for: .applicationDirectory, in: .systemDomainMask)
                for dir in allApps {
                    guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                    for appURL in contents where appURL.pathExtension == "app" {
                        let bundle = Bundle(url: appURL)
                        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                            ?? appURL.deletingPathExtension().lastPathComponent
                        if name == title {
                            return Self.resizedIconData(from: NSWorkspace.shared.icon(forFile: appURL.path))
                        }
                    }
                }
                return nil // Share Menu fallback — no image
            }()
            let supportsRawText = svc.canPerform(withItems: ["Test Text"])
            let provider = QuickShareProvider(id: title, imageData: imgData, supportsRawText: supportsRawText)
            if !providers.contains(provider) {
                providers.append(provider)
                cachedServices[title] = svc
            }
        }
        
        if let idx = providers.firstIndex(where: { $0.id == "AirDrop" }) {
            let ad = providers.remove(at: idx)
            providers.insert(ad, at: 0)
        }

        if !providers.contains(where: { $0.id == "LocalSend" }) {
            // The LocalSend asset is full-bleed (its glyph fills all 1024x1024px),
            // unlike AirDrop/Mail/Notes/ShareMenu which follow Apple's icon
            // template with ~84% content and a margin baked in. Scale it down to
            // match so it doesn't render larger than its siblings in the list.
            let icon = NSImage(named: "LocalSend").flatMap { Self.resizedIconData(from: $0, contentScale: 0.84) }
            providers.insert(QuickShareProvider(id: "LocalSend", imageData: icon, supportsRawText: true), at: min(1, providers.count))
        }

        if !providers.contains(where: { $0.id == "Share Menu" }) {
            let icon = NSImage(named: "ShareMenu").flatMap { Self.resizedIconData(from: $0) }
            providers.append(QuickShareProvider(id: "Share Menu", imageData: icon, supportsRawText: true))
        }

        self.availableProviders = providers

    }
    
    // MARK: - File Picker
    @MainActor
    func showFilePicker(for provider: QuickShareProvider, from view: NSView?) async {
        guard !isPickerOpen else {
            print("⚠️ QuickShareService: File picker already open")
            return
        }

        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Select Files for \(provider.id)"
        panel.message = "Choose files to share via \(provider.id)"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            defer {
                self?.isPickerOpen = false
                SharingStateManager.shared.endInteraction()
            }

            if response == .OK && !panel.urls.isEmpty {
                Task {
                    await self?.shareFilesOrText(panel.urls, using: provider, from: view)
                }
            }
        }

        let response = panel.runModal()
        completion(response)
    }
    
    // MARK: - Sharing
    @MainActor
    func shareFilesOrText(_ items: [Any], using provider: QuickShareProvider, from view: NSView?) async {
        let fileURLs = items.compactMap { $0 as? URL }.filter { $0.isFileURL }
        // Stop any previous sharing access
        stopSharingAccessingURLs()
        // Start security-scoped access for all file URLs
        sharingAccessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }

        if provider.id == "LocalSend" {
            SharingStateManager.shared.beginInteraction()
            defer { SharingStateManager.shared.endInteraction() }
            do {
                try await LocalSendService.shared.send(items: items)
            } catch {
                NSLog("LocalSend send failed: \(error.localizedDescription)")
            }
            stopSharingAccessingURLs()
            return
        }

        // Setup lifecycle delegate to keep notch open during picker/service
        let delegate = SharingStateManager.shared.makeDelegate { [weak self] in
            self?.lifecycleDelegate = nil
            self?.stopSharingAccessingURLs()
        }
        lifecycleDelegate = delegate

        if let svc = cachedServices[provider.id], svc.canPerform(withItems: items) {
            // For direct service path, explicitly mark service interaction start
            delegate.markServiceBegan()
            svc.delegate = delegate
            svc.perform(withItems: items)
        } else {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = delegate
            delegate.markPickerBegan()
            if let view {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        }
    }
    
    /// Renders `image` into a fixed-size, fixed-resolution PNG so menu items
    /// (which use NSImage's native pixel size, not SwiftUI frame modifiers)
    /// never render oversized.
    private static func resizedIconData(from image: NSImage, size: CGFloat = 34, contentScale: CGFloat = 1.0) -> Data? {
        // Some NSSharingService/NSWorkspace icons come back with a zero size
        // when queried too early — bail out to nil so callers fall back to a
        // placeholder instead of caching a blank transparent icon.
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        // Cache at 64pt (2x for the largest place these render — the 34pt
        // drop-zone circle in FileShareView) rather than menu-row size (16pt),
        // so SwiftUI is always downscaling a sharp source instead of
        // upscaling a soft one. NSImage.draw picks the best source
        // representation for this target automatically.
        let target = NSSize(width: size, height: size)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        // contentScale < 1 shrinks the drawn image within the target square
        // (centered) for source assets whose glyph fills the full canvas,
        // so it visually matches sibling icons that already have margin baked in.
        let drawSize = NSSize(width: size * contentScale, height: size * contentScale)
        let drawOrigin = NSPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)
        image.draw(in: NSRect(origin: drawOrigin, size: drawSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        thumb.size = target

        guard let tiff = thumb.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func stopSharingAccessingURLs() {
        NSLog("Stopping sharing access to URLs")
        for url in sharingAccessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        sharingAccessingURLs.removeAll()
    }
// MARK: - SharingServiceDelegate

private class SharingServiceDelegate: NSObject {}
    
    func shareDroppedFiles(_ providers: [NSItemProvider], using shareProvider: QuickShareProvider, from view: NSView?) async {
        var itemsToShare: [Any] = []
        var foundText: String?

        for provider in providers {
            if let webURL = await provider.extractURL() {
                itemsToShare.append(webURL)
            } else if foundText == nil, let text = await provider.extractText() {
                foundText = text
            } else if let itemFileURL = await provider.extractItem() {
                let resolvedURL = await resolveShelfItemBookmark(for: itemFileURL) ?? itemFileURL
                itemsToShare.append(resolvedURL)
            }
        }

        // If text was found, prioritize sharing it.
        if let text = foundText {
            if shareProvider.supportsRawText {
                await shareFilesOrText([text], using: shareProvider, from: view)
            } else {
                if let tempTextURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    await shareFilesOrText([tempTextURL], using: shareProvider, from: view)
                    TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: tempTextURL)
                } else {
                    await shareFilesOrText([text], using: shareProvider, from: view)
                }
            }
        } else if !itemsToShare.isEmpty {
            await shareFilesOrText(itemsToShare, using: shareProvider, from: view)
        }
    }

    private func resolveShelfItemBookmark(for fileURL: URL) async -> URL? {
        let items = await ShelfStateViewModel.shared.items

        for itm in items {
            if let resolved = await ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: itm) {
                if resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    return resolved
                }
            }
        }
        print("❌ Failed to resolve bookmark for shelf item")
        return nil
    }
}

// MARK: - App Storage Extension for Provider Selection

extension QuickShareProvider {
    static var defaultProvider: QuickShareProvider {
        let svc = QuickShareService.shared

        if let airdrop = svc.availableProviders.first(where: { $0.id == "AirDrop" }) {
            return airdrop
        }
        return svc.availableProviders.first ?? QuickShareProvider(id: "Share Menu", imageData: nil, supportsRawText: true)
    }
}
