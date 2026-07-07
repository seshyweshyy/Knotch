//
//  NotchStylePreview.swift
//  Knotch
//
//

import SwiftUI

/// Miniature live preview of a notch appearance style: a sample wallpaper
/// with a scaled-down notch shape rendered on top using the exact same
/// material code path as the real notch, so what you see in Settings is
/// what you'll actually get.
struct NotchStylePreview: View {
    let style: NotchAppearanceStyle

    @State private var wallpaperImage: NSImage?

    private var previewNotchShape: NotchShape {
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
    }

    var body: some View {
        ZStack {
            Group {
                if let wallpaperImage {
                    Image(nsImage: wallpaperImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.3)
                }
            }

            previewNotchShape
                .fill(Color.black)
                .frame(width: 84, height: 34)
                .overlay {
                    notchMaterial
                        .clipShape(previewNotchShape)
                }
                .frame(width: 84, height: 34)
        }
        .task {
            loadCurrentWallpaper()
        }
    }

    private func loadCurrentWallpaper() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url) else {
            return
        }
        wallpaperImage = image
    }

    @ViewBuilder
    private var notchMaterial: some View {
        switch style {
        case .solidBlack:
            Color.black

        case .semiLiquidGlass:
            if #available(macOS 26, *) {
                ZStack {
                    KnotchVariant11Glass()
                    Color.black
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.42),
                                    .init(color: .black.opacity(0.6), location: 0.5),
                                    .init(color: .clear, location: 0.58),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                }
            } else {
                Color.black
            }
        }
    }
}

#Preview {
    HStack {
        NotchStylePreview(style: .solidBlack)
        NotchStylePreview(style: .semiLiquidGlass)
    }
    .frame(width: 300, height: 100)
}
