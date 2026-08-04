//
//  TrayDropService.swift
//  Knotch
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct TrayDropService {
    static func items(from providers: [NSItemProvider]) async -> [TrayItem] {
        var results: [TrayItem] = []

        for provider in providers {
            if let item = await processProvider(provider) {
                results.append(item)
            }
        }

        return results
    }
    
    private static func processProvider(_ provider: NSItemProvider) async -> TrayItem? {
        if let actualFileURL = await provider.extractFileURL() {
            if let bookmark = createBookmark(for: actualFileURL) {
                return await TrayItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
            return nil
        }
        
        if let url = await provider.extractURL() {
            if url.isFileURL {
                if let bookmark = createBookmark(for: url) {
                    return await TrayItem(kind: .file(bookmark: bookmark), isTemporary: false)
                }
            } else {
                return await TrayItem(kind: .link(url: url), isTemporary: false)
            }
            return nil
        }
        
        if let text = await provider.extractText() {
            return await TrayItem(kind: .text(string: text), isTemporary: false)
        }
        
        if let data = await provider.loadData() {
            if let tempDataURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: provider.suggestedName)),
               let bookmark = createBookmark(for: tempDataURL) {
                return await TrayItem(kind: .file(bookmark: bookmark), isTemporary: true)
            }
            return nil
        }
        
        if let fileURL = await provider.extractItem() {
            if let bookmark = createBookmark(for: fileURL) {
                return await TrayItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
        }
        
        return nil
    }
    
    private static func createBookmark(for url: URL) -> Data? {
        return (try? Bookmark(url: url))?.data
    }
}

