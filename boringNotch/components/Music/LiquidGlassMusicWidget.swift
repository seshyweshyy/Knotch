//
//  LiquidGlassMusicWidget.swift
//  boringNotch
//
//  Lock-screen music widget styled to match the iOS lock screen player:
//  large album art top-left, song/artist right of art, progress bar full-width,
//  transport controls centred below. Supports tinted or clear glass via Settings.
//

import SwiftUI
import Defaults

enum LockScreenWidgetStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case tinted = "Tinted"
    case frosted = "Frosted"
    var id: String { rawValue }
}

struct LiquidGlassMusicWidget: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.playerColorTinting) var playerColorTinting
    @Default(.lockScreenWidgetStyle) var widgetStyle

    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var rotationDegrees: Double = 0
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Top row: album art + song info + visualiser ───────────────
            HStack(alignment: .center, spacing: 12) {
                albumArtThumbnail

                VStack(alignment: .leading, spacing: 3) {
                    Text(musicManager.songTitle.isEmpty ? "Not Playing" : musicManager.songTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(musicManager.artistName.isEmpty ? "—" : musicManager.artistName)
                        .font(.subheadline)
                        .foregroundStyle(
                            playerColorTinting
                                ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
                                : Color.white.opacity(0.65)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Visualiser (same as closed notch)
                AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                    .frame(width: 16, height: 12)
                    .colorMultiply(.white)
                    .opacity(0.30)
                    .fixedSize()
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            // ── Progress bar ──────────────────────────────────────────────
            TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
                MusicSliderView(
                    sliderValue: $sliderValue,
                    duration: $musicManager.songDuration,
                    lastDragged: $lastDragged,
                    color: musicManager.avgColor,
                    dragging: $dragging,
                    currentDate: timeline.date,
                    timestampDate: musicManager.timestampDate,
                    elapsedTime: musicManager.elapsedTime,
                    playbackRate: musicManager.playbackRate,
                    isPlaying: musicManager.isPlaying
                ) { newValue in
                    MusicManager.shared.seek(to: newValue)
                }
                .frame(height: 36)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)

            // ── Transport controls ────────────────────────────────────────
            HStack(spacing: 0) {
                Spacer()
                HoverButton(icon: "backward.fill", scale: .medium) {
                    MusicManager.shared.previousTrack()
                }
                HoverButton(
                    icon: musicManager.isPlaying ? "pause.fill" : "play.fill",
                    scale: .large
                ) {
                    MusicManager.shared.togglePlay()
                }
                HoverButton(icon: "forward.fill", scale: .medium) {
                    MusicManager.shared.nextTrack()
                }
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .frame(width: 320)
        .background {
            // Glass style driven by setting
            switch widgetStyle {
            case .tinted:
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
            case .frosted:
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .glassEffect(.clear, in: .rect(cornerRadius: 22))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
        // ── Album art flip ────────────────────────────────────────────────
        .onChange(of: musicManager.artFlipSignal) { _, signal in
            let dir: Double = signal.direction == .forward ? 1 : -1
            withAnimation(.easeIn(duration: 0.15)) { rotationDegrees = dir * 90 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                displayedArt = signal.art
                rotationDegrees = dir * -90
                withAnimation(.easeOut(duration: 0.15)) { rotationDegrees = 0 }
            }
        }
    }

    private var albumArtThumbnail: some View {
        Image(nsImage: displayedArt)
            .resizable()
            .aspectRatio(1, contentMode: .fill)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .rotation3DEffect(.degrees(rotationDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
    }
}
