//
//  QuickShareProviderRow.swift
//  Knotch
//

import SwiftUI
import AppKit

/// Shared icon + label row for QuickShareProvider, used by both the
/// inline shelf popover (FileShareView) and Settings so they stay visually
/// identical and only need styling changes made in one place.
struct QuickShareProviderRow: View {
    let provider: QuickShareProvider
    var iconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            if let imgData = provider.imageData, let nsImg = NSImage(data: imgData) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2))
            } else {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: iconSize, height: iconSize)
                    .foregroundColor(.accentColor)
            }
            Text(provider.id)
                .lineLimit(1)
        }
    }
}