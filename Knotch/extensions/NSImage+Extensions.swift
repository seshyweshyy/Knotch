//
//  Image2Color.swift
//  Knotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import SwiftUI
import AppKit
import Cocoa
import Foundation
import CoreImage
import CoreGraphics
import CoreImage.CIFilterBuiltins

extension NSImage {

    
    func averageColor(completion: @escaping (NSColor?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            let width = cgImage.width
            let height = cgImage.height
            let totalPixels = width * height
            
            guard let context = CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            guard let data = context.data else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            let pointer = data.bindMemory(to: UInt32.self, capacity: totalPixels)
            
            var totalRed: UInt64 = 0
            var totalGreen: UInt64 = 0
            var totalBlue: UInt64 = 0
            
            for i in 0..<totalPixels {
                let color = pointer[i]
                totalRed += UInt64(color & 0xFF)
                totalGreen += UInt64((color >> 8) & 0xFF)
                totalBlue += UInt64((color >> 16) & 0xFF)
            }
            
            let averageRed = CGFloat(totalRed) / CGFloat(totalPixels) / 255.0
            let averageGreen = CGFloat(totalGreen) / CGFloat(totalPixels) / 255.0
            let averageBlue = CGFloat(totalBlue) / CGFloat(totalPixels) / 255.0
            
            let minBrightness: CGFloat = 0.5
            let isNearBlack = averageRed < 0.03 && averageGreen < 0.03 && averageBlue < 0.03
            
            var finalColor: NSColor
            
            if isNearBlack {
                // If it's near black, just return a gray color with the minimum brightness
                finalColor = NSColor(white: minBrightness, alpha: 1.0)
            } else {
                var color = NSColor(red: averageRed, green: averageGreen, blue: averageBlue, alpha: 1.0)
                
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                
                if brightness < minBrightness {
                    // Increase brightness while maintaining hue and reducing saturation
                    let saturationScale = brightness / minBrightness
                    color = NSColor(hue: hue,
                                    saturation: saturation * saturationScale,
                                    brightness: minBrightness,
                                    alpha: alpha)
                }
                
                finalColor = color
            }
            
            DispatchQueue.main.async {
                completion(finalColor)
            }
        }
        
    }
    
    // Extracts `count` visually distinct dominant colours using simple bucket-based k-means.
    func dominantColors(count: Int = 3, completion: @escaping ([NSColor]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            // Downsample to a tiny thumbnail for speed
            let thumb = 64
            guard let ctx = CGContext(data: nil, width: thumb, height: thumb,
                                       bitsPerComponent: 8, bytesPerRow: thumb * 4,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumb, height: thumb))
            guard let data = ctx.data else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let pixels = data.bindMemory(to: UInt32.self, capacity: thumb * thumb)
            var buckets = Array(repeating: (r: 0.0, g: 0.0, b: 0.0, n: 0), count: count)

            // Initialise bucket centres spread across image
            for i in 0..<count {
                let p = pixels[(i * thumb * thumb / count)]
                buckets[i] = (r: Double(p & 0xFF) / 255,
                              g: Double((p >> 8) & 0xFF) / 255,
                              b: Double((p >> 16) & 0xFF) / 255,
                              n: 1)
            }

            // 8 k-means iterations
            for _ in 0..<8 {
                var sums = Array(repeating: (r: 0.0, g: 0.0, b: 0.0, n: 0), count: count)
                for i in 0..<(thumb * thumb) {
                    let p = pixels[i]
                    let r = Double(p & 0xFF) / 255
                    let g = Double((p >> 8) & 0xFF) / 255
                    let b = Double((p >> 16) & 0xFF) / 255
                    var best = 0
                    var bestDist = Double.greatestFiniteMagnitude
                    for k in 0..<count {
                        let d = (r - buckets[k].r) * (r - buckets[k].r)
                              + (g - buckets[k].g) * (g - buckets[k].g)
                              + (b - buckets[k].b) * (b - buckets[k].b)
                        if d < bestDist { bestDist = d; best = k }
                    }
                    sums[best].r += r; sums[best].g += g; sums[best].b += b; sums[best].n += 1
                }
                for k in 0..<count where sums[k].n > 0 {
                    buckets[k] = (r: sums[k].r / Double(sums[k].n),
                                   g: sums[k].g / Double(sums[k].n),
                                   b: sums[k].b / Double(sums[k].n),
                                   n: sums[k].n)
                }
            }

            let colors = buckets.map { NSColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
            DispatchQueue.main.async { completion(colors) }
        }
    }
    
    func getBrightness() -> CGFloat {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }
        
        let inputImage = CIImage(cgImage: cgImage)
        
        let filter = CIFilter.areaAverage()
        filter.inputImage = inputImage
        filter.extent = inputImage.extent
        
        guard let outputImage = filter.outputImage else {
            return 0
        }
        
        let context = CIContext(options: nil)
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        
        let brightness = (0.2126 * CGFloat(bitmap[0]) + 0.7152 * CGFloat(bitmap[1]) + 0.0722 * CGFloat(bitmap[2])) / 255.0
        
        return brightness
    }
}

extension Color {
    func ensureMinimumBrightness(factor: CGFloat) -> Color {
        guard factor >= 0 && factor <= 1 else {
            return self // Return original color if factor is out of bounds
        }
        
        let nsColor = NSColor(self)
        
        // Convert to RGB color space
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return self // Return original color if conversion fails
        }
        
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        // Calculate perceived brightness using the formula: (0.299*R + 0.587*G + 0.114*B)
        let perceivedBrightness = (0.2126 * red + 0.7152 * green + 0.0722 * blue)
        
        let scale = factor / perceivedBrightness
        red = min(red * scale, 1.0)
        green = min(green * scale, 1.0)
        blue = min(blue * scale, 1.0)
        
        return Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }
}
