//
//  LiquidGlassMusicWidget.swift
//  Knotch
//
//  Lock-screen music widget styled to match the iOS lock screen player:
//  large album art top-left, song/artist right of art, progress bar full-width,
//  transport controls centred below.
//

import SwiftUI
import Defaults

enum LockScreenWidgetStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case frosted = "Frosted"
    var id: String { rawValue }
}

// Hit-testing for the album art thumbnail is handled outside SwiftUI/AppKit's
// normal view dispatch entirely — see AlbumArtHitRegion and the click monitor
// in LiquidGlassWidgetWindowController. This view only reports its own frame.

struct LiquidGlassMusicWidget: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.playerColorTinting) var playerColorTinting
    @Default(.lockScreenExpandedAlbumArt) var expandedAlbumArtEnabled

    @Binding var isExpanded: Bool
    var artNamespace: Namespace.ID
    var onArtFrameChange: (CGRect) -> Void = { _ in }

    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var rotationDegrees: Double = 0
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                innerContent
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
            }
            .onChange(of: musicManager.artFlipSignal) { _, signal in flipArt(signal) }
        } else {
            innerContent
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.black.opacity(0.55))
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
                .onChange(of: musicManager.artFlipSignal) { _, signal in flipArt(signal) }
        }
    }

    @ViewBuilder
    private var innerContent: some View {
        VStack(alignment: isExpanded ? .center : .leading, spacing: 0) {
            // ── Top row ──
            HStack(alignment: .center, spacing: 12) {
                if !isExpanded { albumArtThumbnail }
                VStack(alignment: isExpanded ? .center : .leading, spacing: 3) {
                    MarqueeText(
                        .constant(musicManager.songTitle.isEmpty ? "Not Playing" : musicManager.songTitle),
                        font: .headline,
                        nsFont: .headline,
                        textColor: .white,
                        frameWidth: isExpanded ? 260 : 180
                    )
                    .fontWeight(.semibold)
                    .id("title-\(isExpanded)")
                    .edgeFade()
                    MarqueeText(
                        .constant(musicManager.artistName.isEmpty ? "—" : musicManager.artistName),
                        font: .subheadline,
                        nsFont: .subheadline,
                        textColor: playerColorTinting
                            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
                            : Color.white.opacity(0.65),
                        frameWidth: isExpanded ? 260 : 180
                    )
                    .id("artist-\(isExpanded)")
                    .edgeFade()
                }
                .frame(maxWidth: .infinity)
                Spacer()
                AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                    .frame(width: AudioSpectrum.recommendedFrameSize.width, height: AudioSpectrum.recommendedFrameSize.height)
                    .colorMultiply(.white)
                    .opacity(0.50)
                    .fixedSize()
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 14)
            .padding(.top, isExpanded ? 12 : 14)

            // ── Progress bar ──
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
                .frame(height: 36)
                .colorMultiply(Color.white)
            }
            .onAppear {
                let target = MusicManager.shared.estimatedPlaybackPosition(at: Date())
                withAnimation(.easeOut(duration: 0.4)) { sliderValue = target }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)

            // ── Transport controls ──
            MusicSlotToolbar(isLockScreenContext: true)
                .padding(.bottom, 8)
        }
        .frame(width: 320)
    }

    private func flipArt(_ signal: ArtFlipSignal) {
        let dir: Double = signal.direction == .forward ? 1 : -1
        withAnimation(.easeIn(duration: 0.15)) { rotationDegrees = dir * 90 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            displayedArt = signal.art
            rotationDegrees = dir * -90
            withAnimation(.easeOut(duration: 0.15)) { rotationDegrees = 0 }
        }
    }

    @ViewBuilder private var topGradientOverlay: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(
                stops: [
                    .init(color: .white.opacity(isExpanded ? 0.18 : 0.10), location: 0),
                    .init(color: .white.opacity(isExpanded ? 0.06 : 0.03), location: 0.3),
                    .init(color: .clear, location: 0.6),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            .allowsHitTesting(false)
    }

    @ViewBuilder private var topBorderOverlay: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LinearGradient(
                stops: [
                    .init(color: .white.opacity(isExpanded ? 0.55 : 0.22), location: 0),
                    .init(color: .white.opacity(isExpanded ? 0.15 : 0.05), location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var bottomBorderOverlay: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.5),
                    .init(color: .white.opacity(isExpanded ? 0.35 : 0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 2.5)
            .allowsHitTesting(false)
    }

    private var albumArtThumbnail: some View {
        Image(nsImage: displayedArt)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .matchedGeometryEffect(id: "albumArt", in: artNamespace)
            .rotation3DEffect(.degrees(rotationDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(false)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            onArtFrameChange(isExpanded ? .zero : proxy.frame(in: .named("widgetRootSpace")))
                        }
                        .onChange(of: proxy.frame(in: .named("widgetRootSpace"))) { _, newFrame in
                            onArtFrameChange(isExpanded ? .zero : newFrame)
                        }
                        .onChange(of: isExpanded) { _, expanded in
                            onArtFrameChange(expanded ? .zero : proxy.frame(in: .named("widgetRootSpace")))
                        }
                }
            )
    }
}
