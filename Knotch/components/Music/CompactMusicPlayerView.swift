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
    @Default(.forceSimulatedNotch) private var forceSimulatedNotch
    @Default(.debugForceDynamicIslandAppearance) private var debugForceDynamicIslandAppearance
    let albumArtNamespace: Namespace.ID

    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    private let albumArtSize: CGFloat = 55

    // No physical notch to hug in Dynamic Island appearance — the reserved
    // space above the header only needs to fit the album art's own pull-up,
    // not the real notch cutout's height, which on some setups (custom/
    // non-notch height settings) is taller than that pull-up actually needs.
    private var isIslandAppearance: Bool {
        usesDynamicIslandAppearance(
            screenUUID: vm.screenUUID,
            forceSimulatedNotch: forceSimulatedNotch,
            debugForceDynamicIsland: debugForceDynamicIslandAppearance
        )
    }

    private var pullUp: CGFloat {
        isIslandAppearance ? 20 : max(vm.effectiveClosedNotchHeight - 4, 20)
    }

    // Extra clearance added on top of pullUp's own reservation, pushing the
    // whole header (art/title/artist/waveform) and progress bar down from
    // the top corners. Bumping pullUp itself doesn't achieve this — the
    // reservation below grows by the same amount the art rises into it
    // (see notchHuggingHeader's `.offset(y: -pullUp)`), so the two cancel
    // out and the art's actual position on screen never moves. This is
    // added independently of that cancellation, purely to push things down.
    private var extraTopPush: CGFloat {
        isIslandAppearance ? 8 : 0
    }

    // compactContentSafeInset (35pt corner + 15pt slack) was tuned to clear
    // the physical notch shape's concave top-corner carve — the island's
    // outer clip is a plain convex rounded rect instead, which doesn't eat
    // nearly as far into the sides, so that inset reads as excess side
    // padding here.
    private var horizontalInset: CGFloat {
        isIslandAppearance ? 22 : compactContentSafeInset
    }

    private var panelWidth: CGFloat {
        compactPanelWidth(isIsland: isIslandAppearance)
    }

    var body: some View {
        // Pinned to compactOpenNotchSize.width (the fixed target), not a
        // live-proposed GeometryReader value — otherwise content that
        // recomputes its own layout from that width (CustomSlider) visibly
        // redraws/grows with the box instead of appearing already at full
        // size, with only the outer clip's reveal changing during the animation.
        VStack(spacing: 0) {
            notchHuggingHeader

            progressBar
                // Pushed down further than the header's own natural gap —
                // Music's total content is shorter than compactContentHeight
                // (tuned for the tallest compact page), so absorbing some of
                // that leftover room as deliberate spacing here reads as
                // intentional breathing room instead of it all collecting as
                // one stray gap below the toolbar. The bigger push is
                // island-only — physical notch keeps its original value.
                .padding(.top, isIslandAppearance ? 17 : 14)

            MusicSlotToolbar(spacing: 12)
                .scaleEffect(1.12)
                // Island-only — physical notch keeps its original gap.
                .padding(.top, isIslandAppearance ? 6 : 10)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: panelWidth, height: compactContentHeight, alignment: .top)
        // Added *outside* the shared frame above, so compactContentHeight
        // itself (and therefore CompactCalendarView, which also uses it to
        // keep the panel the same size across tabs) is untouched. Reserves
        // room for notchHuggingHeader's album art to pull up into — without
        // it, the art's own upward offset just pushes everything flush
        // against this view's own top edge instead of hugging the physical
        // notch cutout with real breathing room above it. Tied to pullUp
        // itself (rather than the raw notch height) so this never reserves
        // more than the art actually rises — a too-generous reservation
        // pushes the toolbar row below it past compactContentHeight's own
        // budget, into the outer clip shape's bottom corner curve.
        .padding(.top, pullUp + 4 + extraTopPush)
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
                    AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace, size: albumArtSize, pausedFadeOpacity: 0.4, cornerRadiusScale: 0.7)
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
                // Island-only nudge closer to the trailing edge — physical
                // notch keeps its original clearance.
                .padding(.trailing, isIslandAppearance ? 3 : 8)
                .frame(width: totalWidth)
                .offset(y: -pullUp + (albumArtSize - spectrumHeight) / 2)

                Button {
                    musicManager.openMusicApp()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        BlurRevealText(musicManager.songTitle) { title in
                            MarqueeText(
                                .constant(title),
                                font: .system(size: 13, weight: .semibold),
                                nsFont: .body,
                                textColor: musicManager.hasActiveSession ? .white : Color.white.opacity(0.65),
                                frameWidth: max(0, textAreaWidth - textLeadingInset),
                                trailingIcons: musicManager.trackBadges(
                                    explicitColor: Color(white: 0.55), qualityColor: Color(white: 0.38)
                                ),
                                // This view stays mounted and fades out on
                                // close, so without this it'd keep scrolling
                                // invisibly and be mid-cycle on reopen.
                                isPaused: vm.notchState == .closed
                            )
                        }
                        if musicManager.hasActiveSession {
                            BlurRevealText(musicManager.artistName) { artist in
                                Text(artist)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(
                                        Defaults[.playerColorTinting]
                                            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray
                                    )
                                    .lineLimit(1)
                            }
                        }
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
                // Physical notch: bottom of the text lines up with the
                // bottom of the (pulled-up) album art (nudged up a bit
                // further still). Island: vertically centered against the
                // album art's own midpoint instead — pullUp is a fixed,
                // smaller value there, so the bottom-aligned formula reads
                // as sitting low rather than sitting next to the art.
                .offset(y: isIslandAppearance
                    ? (albumArtSize / 2 - pullUp - 15)
                    : (albumArtSize - pullUp - 33))
            }
        }
        .frame(height: 26)
    }

    // Same style as the lock screen widget (LiquidGlassMusicWidget): inline
    // time labels beside the track, remaining time on the trailing side.
    private var progressBar: some View {
        // Fixed width pin, same reasoning as body's outer frame — without it
        // the two .fixedSize() timestamp labels + flexible CustomSlider
        // sized off their own ideal width, cutting labels off at the clip.
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
                inlineTimestamps: true,
                isLive: musicManager.isLiveBrowserStream
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .frame(width: panelWidth - 2 * horizontalInset, height: 24)
        }
    }
}
