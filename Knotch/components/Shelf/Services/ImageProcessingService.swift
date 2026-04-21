//
//  ImageProcessingService.swift
//  Knotch
//
//  Created by Alexander on 2025-10-16.
//

import Foundation
import AppKit
import CoreImage
import CoreGraphics
import Vision
import PDFKit
import ZIPFoundation
import UniformTypeIdentifiers
import ImageIO

/// Options for image conversion
struct ImageConversionOptions {
    enum ImageFormat {
        case png, jpeg, heic, tiff, bmp
        
        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .tiff: return .tiff
            case .bmp: return .bmp
            }
        }
        
        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .tiff: return "tiff"
            case .bmp: return "bmp"
            }
        }
    }
    
    let format: ImageFormat
    let compressionQuality: Double // 0.0 to 1.0, only applies to JPEG/HEIC
    let maxDimension: CGFloat? // Max width or height, nil for no scaling
    let removeMetadata: Bool
}

/// Service for processing images (background removal, conversion, PDF creation)
@MainActor
final class ImageProcessingService {
    static let shared = ImageProcessingService()
    
    private init() {}
    private let ciContext = CIContext(options: nil)
    
    // MARK: - Remove Background
    
    /// Removes the background from an image using Vision framework
    func removeBackground(from url: URL) async throws -> URL? {
        guard let inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }
        
        guard let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageProcessingError.invalidImage
        }
        
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        
        try handler.perform([request])
        
        guard let result = request.results?.first else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        
        let output = try await applyMask(mask, to: cgImage)
        
        let processedImage = NSImage(cgImage: output, size: inputImage.size)
        
        // Create temporary file
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_no_bg.png"
        
        guard let pngData = processedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: pngData),
              let finalData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageProcessingError.saveFailed
        }
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(finalData, suggestedName: newName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    private func applyMask(_ mask: CVPixelBuffer, to image: CGImage) async throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: mask)
        
        let filter = CIFilter.blendWithMask()
        filter.inputImage = ciImage
        filter.maskImage = maskImage
        filter.backgroundImage = CIImage.empty()
        
        guard let output = filter.outputImage else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        let context = CIContext()
        guard let result = context.createCGImage(output, from: output.extent) else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        return result
    }
    
    // MARK: - Convert Image
    
    /// Converts an image with specified options
    func convertImage(from url: URL, options: ImageConversionOptions) async throws -> URL? {
        guard var inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }
        
        // Scale image if needed
        if let maxDim = options.maxDimension {
            inputImage = scaleImage(inputImage, maxDimension: maxDim)
        }
        
        // Get image data based on format
        let imageData: Data?
        
        if options.removeMetadata {
            // Create new image without metadata
            guard let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ImageProcessingError.invalidImage
            }
            
            let newImage = NSImage(cgImage: cgImage, size: inputImage.size)
            imageData = try convertToFormat(newImage, format: options.format, quality: options.compressionQuality)
        } else {
            imageData = try convertToFormat(inputImage, format: options.format, quality: options.compressionQuality)
        }
        
        guard let data = imageData else {
            throw ImageProcessingError.conversionFailed
        }
        
        // Create temporary file
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_converted.\(options.format.fileExtension)"
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(data, suggestedName: newName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    private func convertToFormat(_ image: NSImage, format: ImageConversionOptions.ImageFormat, quality: Double) throws -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        switch format {
        case .png:
            return bitmap.representation(using: .png, properties: [:])
        case .jpeg:
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionFactor: quality
            ]
            return bitmap.representation(using: .jpeg, properties: properties)
        case .tiff:
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)
            ]
            return bitmap.representation(using: .tiff, properties: properties)
        case .bmp:
            return bitmap.representation(using: .bmp, properties: [:])
        case .heic:
            // HEIC requires using CIContext
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let ciImage = CIImage(cgImage: cgImage)
            let context = CIContext()
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ]
            return try? context.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: options)
        }
    }
    
    private func scaleImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        guard maxDimension > 0 else { return image }
        
        guard let srcCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        
        let srcMax = max(srcCG.width, srcCG.height)
        if CGFloat(srcMax) <= maxDimension {
            return image // no downscaling needed
        }
        
        let scale = maxDimension / CGFloat(srcMax)
        
        let ciImage = CIImage(cgImage: srcCG)
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = ciImage
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1.0
        
        guard let output = lanczos.outputImage else {
            return image
        }
        
        // Preserve the source color space for exact color matching
        let colorSpace = srcCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = CIContext(options: [.workingColorSpace: colorSpace])
        
        // Render using the CIContext with matching color space
        guard let dstCG = ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return image
        }
        
        return NSImage(cgImage: dstCG, size: NSSize(width: dstCG.width, height: dstCG.height))
    }
    
    // MARK: - Create PDF
    
    /// Creates a PDF from multiple image URLs
    func createPDF(from imageURLs: [URL], outputName: String? = nil) async throws -> URL? {
        guard !imageURLs.isEmpty else {
            throw ImageProcessingError.noImagesProvided
        }
        
        let pdfDocument = PDFDocument()
        
        for (index, url) in imageURLs.enumerated() {
            guard let image = NSImage(contentsOf: url) else {
                continue
            }
            
            let pdfPage = PDFPage(image: image)
            if let page = pdfPage {
                pdfDocument.insert(page, at: index)
            }
        }
        
        guard pdfDocument.pageCount > 0 else {
            throw ImageProcessingError.pdfCreationFailed
        }
        
        // Create temporary file
        let name = outputName ?? "images_\(Date().timeIntervalSince1970).pdf"
        let pdfName = name.hasSuffix(".pdf") ? name : "\(name).pdf"
        
        guard let pdfData = pdfDocument.dataRepresentation() else {
            throw ImageProcessingError.pdfCreationFailed
        }
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(pdfData, suggestedName: pdfName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    // MARK: - Helper Methods
    
    /// Checks if a URL is an image file
    func isImageFile(_ url: URL) -> Bool {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return contentType.conforms(to: .image)
    }
    
    // MARK: - PDF to Text
    
    /// Extracts all text from a PDF and saves as a .txt file
    func extractTextFromPDF(at url: URL) async throws -> URL {
        guard let document = PDFDocument(url: url) else {
            throw ImageProcessingError.pdfReadFailed
        }
        
        var pages: [String] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let text = page.string ?? ""
            if !text.isEmpty {
                pages.append("--- Page \(i + 1) ---\n\(text)")
            }
        }
        
        guard !pages.isEmpty else {
            throw ImageProcessingError.pdfNoTextContent
        }
        
        let fullText = pages.joined(separator: "\n\n")
        let baseName = url.deletingPathExtension().lastPathComponent
        let fileName = "\(baseName).txt"
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(fullText.data(using: .utf8)!, suggestedName: fileName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    // MARK: - PDF to DOCX
    
    /// Converts a text-based PDF to .docx using Open XML format (no dependencies)
    func convertPDFtoDOCX(at url: URL) async throws -> URL {
        guard let document = PDFDocument(url: url) else {
            throw ImageProcessingError.pdfReadFailed
        }
        
        struct PageContent {
            let number: Int
            let text: String
        }
        
        var pages: [PageContent] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            
            // Prefer native text — fast and accurate for text-based PDFs
            let nativeText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !nativeText.isEmpty {
                pages.append(PageContent(number: i + 1, text: nativeText))
                continue
            }
            
            // Fallback: rasterize the page and OCR it with Vision
            let pageRect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0 // 144 dpi — good OCR quality without being huge
            let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            
            guard let context = CGContext(
                data: nil,
                width: Int(renderSize.width),
                height: Int(renderSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: renderSize))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            
            guard let cgImage = context.makeImage() else { continue }
            
            let ocrText = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let request = VNRecognizeTextRequest { req, err in
                    if let err {
                        continuation.resume(throwing: err)
                        return
                    }
                    let recognized = (req.results as? [VNRecognizedTextObservation] ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    continuation.resume(returning: recognized)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            
            let trimmedOCR = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOCR.isEmpty {
                pages.append(PageContent(number: i + 1, text: trimmedOCR))
            }
        }
        
        guard !pages.isEmpty else {
            throw ImageProcessingError.pdfNoTextContent
        }
        
        let baseName = url.deletingPathExtension().lastPathComponent
        
        // Build the DOCX Open XML package in a temp directory
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let docxDir = tempDir.appendingPathComponent("docx", isDirectory: true)
        
        let wordDir   = docxDir.appendingPathComponent("word", isDirectory: true)
        let relsDir   = docxDir.appendingPathComponent("_rels", isDirectory: true)
        let wordRels  = wordDir.appendingPathComponent("_rels", isDirectory: true)
        
        try FileManager.default.createDirectory(at: wordRels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir,  withIntermediateDirectories: true)
        
        // [Content_Types].xml
        let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml"  ContentType="application/xml"/>
      <Override PartName="/word/document.xml"
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """
        try contentTypes.data(using: .utf8)!
            .write(to: docxDir.appendingPathComponent("[Content_Types].xml"))
        
        // _rels/.rels
        let dotRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1"
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        Target="word/document.xml"/>
    </Relationships>
    """
        try dotRels.data(using: .utf8)!
            .write(to: relsDir.appendingPathComponent(".rels"))
        
        // word/_rels/document.xml.rels
        let docRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    </Relationships>
    """
        try docRels.data(using: .utf8)!
            .write(to: wordRels.appendingPathComponent("document.xml.rels"))
        
        // word/document.xml — one paragraph per line, page breaks between pages
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        var bodyXML = ""
        
        for (idx, page) in pages.enumerated() {
            // Page break before every page except the first
            if idx > 0 {
                bodyXML += """
            <w:p>
              <w:r>
                <w:br w:type="page"/>
              </w:r>
            </w:p>
            """
            }
            
            let lines = page.text.components(separatedBy: .newlines)
            for line in lines {
                let escaped = line
                    .replacingOccurrences(of: "&",  with: "&amp;")
                    .replacingOccurrences(of: "<",  with: "&lt;")
                    .replacingOccurrences(of: ">",  with: "&gt;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "'",  with: "&apos;")
                
                let trimmed = escaped.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    bodyXML += "<w:p/>\n"
                } else {
                    bodyXML += """
                <w:p>
                  <w:r><w:t xml:space="preserve">\(trimmed)</w:t></w:r>
                </w:p>
                """
                }
            }
        }
        
        let documentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document \(ns)>
      <w:body>
    \(bodyXML)
      </w:body>
    </w:document>
    """
        try documentXML.data(using: .utf8)!
            .write(to: wordDir.appendingPathComponent("document.xml"))
        
        // ZIP the docx directory into a .docx file
        let outputURL = tempDir.appendingPathComponent("\(baseName).docx")
        try FileManager.default.zipItem(at: docxDir, to: outputURL, shouldKeepParent: false)
        
        return outputURL
    }
    // MARK: - Helpers
    
    func isPDFFile(_ url: URL) -> Bool {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return contentType.conforms(to: .pdf)
    }
}

// MARK: - Errors

enum ImageProcessingError: LocalizedError {
    case invalidImage
    case backgroundRemovalFailed
    case conversionFailed
    case pdfCreationFailed
    case pdfReadFailed
    case pdfNoTextContent
    case noImagesProvided
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The file is not a valid image"
        case .backgroundRemovalFailed:
            return "Failed to remove background from image"
        case .conversionFailed:
            return "Failed to convert image format"
        case .pdfCreationFailed:
            return "Failed to create PDF from images"
        case .noImagesProvided:
            return "No images were provided"
        case .saveFailed:
            return "Failed to save processed file"
        case .pdfReadFailed:
            return "Could not open the PDF file"
        case .pdfNoTextContent:
            return "This PDF contains no extractable text or recognizable content."
        }
    }
}
