import SwiftUI

/// Miniature live preview of a notch appearance style: a sample wallpaper
/// with a scaled-down notch shape rendered on top using the exact same
/// material code path as the real notch, so what you see in Settings is
/// what you'll actually get.
struct NotchStylePreview: View {
    let style: NotchAppearanceStyle

    private var previewNotchShape: NotchShape {
        NotchShape(topCornerRadius: 3, bottomCornerRadius: 7)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Swap this for whatever your actual bundled sample wallpaper
            // asset is named — it's the same image already shown in your
            // Notch Style picker thumbnails.
            Image("PreviewWallpaper")
                .resizable()
                .aspectRatio(contentMode: .fill)

            previewNotchShape
                .fill(Color.black)
                .frame(width: 56, height: 18)
                .overlay {
                    notchMaterial
                        .clipShape(previewNotchShape)
                }
                .frame(width: 56, height: 18)
        }
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
                    Color.black.opacity(0.35)
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