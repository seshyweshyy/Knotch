import Defaults
import SwiftUI

/// Native in-window glass samples the wallpaper directly behind the notch.
struct NotchStylePreview: View {
    let style: NotchAppearanceStyle
    @ObservedObject private var wallpaper = SettingsPreviewWallpaper.shared
    @Default(.semiLiquidGlassTransition) private var glassAmount

    private var previewNotchShape: NotchShape {
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
    }

    var body: some View {
        ZStack {
            if let image = wallpaper.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
            notchMaterial
                .frame(width: 84, height: 34)
        }
        .task { wallpaper.refresh() }
    }

    @ViewBuilder
    private var notchMaterial: some View {
        if style == .solidBlack {
            previewNotchShape.fill(.black)
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.clear, in: previewNotchShape)
                .overlay {
                    if style == .semiLiquidGlass {
                        let midpoint = 1 - glassAmount
                        let start = max(0, midpoint - 0.15)
                        let end = min(1, midpoint + 0.15)
                        previewNotchShape.fill(.black)
                            .mask {
                                LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: start),
                                    .init(color: .black.opacity(0.6), location: (start + end) / 2),
                                    .init(color: .clear, location: end),
                                    .init(color: .clear, location: 1)
                                ], startPoint: .top, endPoint: .bottom)
                            }
                    } else {
                        previewNotchShape.fill(.black.opacity(0.25))
                    }
                }
        } else {
            previewNotchShape.fill(.ultraThinMaterial)
        }
    }
}

#Preview {
    HStack {
        NotchStylePreview(style: .solidBlack)
        NotchStylePreview(style: .semiLiquidGlass)
        NotchStylePreview(style: .fullLiquidGlass)
    }
    .frame(width: 300, height: 100)
}
