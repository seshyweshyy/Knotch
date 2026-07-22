//
//  CompactMusicPlayerView.swift
//  Knotch
//
//  Compact mode's music player: a smaller, notch-hugging layout built on
//  Knotch's existing AlbumArtView/MusicSliderView/MusicSlotToolbar rather than
//  the standard side-by-side home view layout.
//

import Defaults
import SwiftUI

struct CompactMusicPlayerView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject private var musicManager = MusicManager.shared
    let albumArtNamespace: Namespace.ID

    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    private let albumArtSize: CGFloat = 55

    private var pullUp: CGFloat {
        max(vm.effectiveClosedNotchHeight - 4, 20)
    }

    var body: some View {
        VStack(spacing: 0) {
            notchHuggingHeader

            progressBar
                .padding(.top, 6)

            MusicSlotToolbar(spacing: 10)
                .scaleEffect(1.12)
                .padding(.top, 10)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        // Shared with CompactCalendarView so the panel is exactly the same
        // size switching between the two — this view's natural height is
        // otherwise shorter than the calendar's, which let the whole panel
        // shrink and grow between the two.
        .frame(height: compactContentHeight, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    // The album art overlaps upward alongside the physical notch cutout instead
    // of sitting in-flow, and the title/artist block sits to its right,
    // positioned so its bottom edge lines up with the art's (now raised) bottom
    // edge — a "U" wrapping around the notch rather than a plain row underneath
    // it. Only the text portion reserves layout height; the art overflows above it.
    private var notchHuggingHeader: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let baseSpectrumSize = AudioSpectrum.recommendedFrameSize
            let spectrumScale: CGFloat = 1.1
            let spectrumWidth = baseSpectrumSize.width * spectrumScale
            let spectrumHeight = baseSpectrumSize.height * spectrumScale
            // A few points of the text's own leading edge sit inside the fade
            // mask's ramp — indent the text past it so the mask only ever eats
            // into blank space, not real characters.
            let textLeadingInset: CGFloat = 8
            let textAreaWidth = max(0, totalWidth - albumArtSize - 4 - spectrumWidth - 16)

            ZStack(alignment: .top) {
                HStack {
                    AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace, size: albumArtSize, pausedFadeOpacity: 0.95, cornerRadiusScale: 0.7)
                    Spacer()
                }
                .offset(y: -pullUp)
                .frame(width: totalWidth)

                // Positioned as its own layer so it lines up vertically with
                // the album art's own bounds, rather than with the text row
                // sitting lower down.
                HStack {
                    Spacer()
                    // Same album-art-tinted waveform used in the standard home
                    // view (MusicControlsWithVisualizer), rather than the plain
                    // white bars used on the lock screen widget.
                    AlbumArtWaveformMask(albumArt: musicManager.albumArt, isPlaying: $musicManager.isPlaying)
                        .frame(width: baseSpectrumSize.width, height: baseSpectrumSize.height)
                        .scaleEffect(spectrumScale)
                        .frame(width: spectrumWidth, height: spectrumHeight)
                }
                .padding(.trailing, 8)
                .frame(width: totalWidth)
                .offset(y: -pullUp + (albumArtSize - spectrumHeight) / 2)

                Button {
                    musicManager.openMusicApp()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        MarqueeText(
                            $musicManager.songTitle,
                            font: .system(size: 13, weight: .semibold),
                            nsFont: .subheadline,
                            textColor: .white,
                            frameWidth: max(0, textAreaWidth - textLeadingInset)
                        )
                        Text(musicManager.artistName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(
                                Defaults[.playerColorTinting]
                                    ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray
                            )
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, textLeadingInset)
                .frame(width: textAreaWidth, alignment: .leading)
                .edgeFade()
                .padding(.leading, albumArtSize + 4)
                // ZStack(alignment: .top) centers children horizontally by
                // default — without this, the fixed-width text box above gets
                // centered in the panel before the leading padding is even
                // applied, instead of hugging the left edge next to the art.
                .frame(maxWidth: .infinity, alignment: .leading)
                // Bottom of the text lines up with the bottom of the
                // (pulled-up) album art (nudged up a bit further still).
                .offset(y: albumArtSize - pullUp - 33)
            }
        }
        .frame(height: 26)
    }

    // Same style as the lock screen widget (LiquidGlassMusicWidget): inline
    // time labels beside the track, remaining time on the trailing side.
    private var progressBar: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !musicManager.isPlaying)) { timeline in
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
                isPlaying: musicManager.isPlaying,
                showRemainingTime: true,
                inlineTimestamps: true
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .frame(height: 24)
        }
    }
}
