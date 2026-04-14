//
//  LiquidGlassMusicWidget.swift
//  boringNotch
//
//  Lock-screen music widget. Uses the same HoverButton + MusicSliderView
//  components as the notch player so styling is identical.
//

import SwiftUI
import Defaults

struct LiquidGlassMusicWidget: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.playerColorTinting) var playerColorTinting

    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var rotationDegrees: Double = 0
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    var body: some View {
        ZStack {
            // ── Glass surface ─────────────────────────────────────────────
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)

            // ── Shimmer border ────────────────────────────────────────────
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.5),
                            Color.white.opacity(0.07),
                            Color.white.opacity(0.22),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )

            // ── Content ───────────────────────────────────────────────────
            HStack(spacing: 10) {
                albumArtThumbnail
                    .padding(.leading, 4)

                VStack(alignment: .leading, spacing: 0) {
                    // Song + artist
                    Text(musicManager.songTitle.isEmpty ? "Not Playing" : musicManager.songTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(musicManager.artistName.isEmpty ? "—" : musicManager.artistName)
                        .font(.subheadline)
                        .foregroundStyle(
                            playerColorTinting
                                ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
                                : Color.gray
                        )
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Progress bar — same MusicSliderView used in the notch
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
                        .padding(.top, 2)
                        .frame(height: 32)
                    }

                    // Transport controls — same HoverButton used in the notch
                    HStack(spacing: 0) {
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
                    }
                    .padding(.top, 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 28, x: 0, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
        .frame(width: 340, height: 130)
        // ── Album art flip — identical to AlbumArtView in the notch ──────
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
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .rotation3DEffect(.degrees(rotationDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
    }
}
