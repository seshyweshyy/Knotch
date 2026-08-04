// ImageConverter.swift
// Knotch

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable {
    case png  = "PNG"
    case jpg  = "JPEG"
    case heic = "HEIC"
    case tiff = "TIFF"
    case webp = "WebP"
    case bmp  = "BMP"

    var uti: UTType {
        switch self {
        case .png:  return .png
        case .jpg:  return .jpeg
        case .heic: return UTType(filenameExtension: "heic") ?? .heic
        case .tiff: return .tiff
        case .webp: return UTType(filenameExtension: "webp") ?? .webP
        case .bmp:  return UTType(filenameExtension: "bmp")  ?? .bmp
        }
    }

    var fileExtension: String { rawValue.lowercased() }
}

enum ImageConverterError: LocalizedError {
    case unreadableSource
    case noFrames
    case destinationCreationFailed
    case encodingFailed
    case unsupportedFormat(ImageFormat)

    var errorDescription: String? {
        switch self {
        case .unreadableSource:           return "Could not read the source image."
        case .noFrames:                   return "Source image contains no frames."
        case .destinationCreationFailed:  return "Could not create output file."
        case .encodingFailed:             return "Failed to write image data."
        case .unsupportedFormat(let f):   return "\(f.rawValue) is not supported on this system."
        }
    }
}

struct ImageConverter {
    /// Format-picker alert + save panel + convert flow shared by every entry
    /// point that lets a user convert a single image file (the tray item
    /// context menu, the compact drop-to-convert zone). Runs its modals
    /// synchronously on the main thread.
    @MainActor
    static func presentConversionDialog(for fileURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Convert Image"
        alert.informativeText = "Choose a format to convert \"\(fileURL.lastPathComponent)\" to:"

        let currentExt = fileURL.pathExtension.lowercased()
        let availableFormats = ImageFormat.allCases.filter { $0.fileExtension != currentExt }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24), pullsDown: false)
        for format in availableFormats {
            popup.addItem(withTitle: format.rawValue)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Convert…")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selectedIndex = popup.indexOfSelectedItem
        guard availableFormats.indices.contains(selectedIndex) else { return }
        let format = availableFormats[selectedIndex]

        // Save panel — this grants sandbox write access to the chosen location
        let savePanel = NSSavePanel()
        savePanel.title = "Convert Image"
        savePanel.prompt = "Convert"
        savePanel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent
        savePanel.allowedContentTypes = [format.uti]
        savePanel.directoryURL = fileURL.deletingLastPathComponent()

        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }

        fileURL.accessSecurityScopedResource { scoped in
            do {
                try ImageConverter.convert(scoped, to: format, outputURL: outputURL)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Conversion Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Converts the image at `sourceURL` to `format`, writing to `outputURL`.
    /// `outputURL` must already be sandbox-accessible (e.g. chosen via NSSavePanel).
    @discardableResult
    static func convert(_ sourceURL: URL, to format: ImageFormat, outputURL: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ImageConverterError.unreadableSource
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw ImageConverterError.noFrames
        }
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, format.uti.identifier as CFString, 1, nil
        ) else {
            throw ImageConverterError.destinationCreationFailed
        }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageConverterError.encodingFailed
        }

        return outputURL
    }
}
