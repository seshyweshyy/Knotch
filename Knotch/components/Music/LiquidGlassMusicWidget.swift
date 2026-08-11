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
    @State private var flipBlur: CGFloat = 0
    @State private var flipBrightness: Double = 0
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    var body: some View {
        if #available(macOS 26.0, *) {
            // style: 0 (.regular) instead of the main notch's .clear — a
            // confirmed-working reference project renders genuinely visible
            // lock-screen glass using .regular, not .clear. controlActiveState
            // forced active since this window never becomes the frontmost
            // app, which otherwise makes AppKit dim materials as "inactive".
            innerContent
                .background(KnotchLiquidGlass(shape: .roundedRect(cornerRadius: 22), adaptiveAppearance: true, style: 0))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
                .environment(\.controlActiveState, .active)
                .onChange(of: musicManager.artFlipSignal) { _, signal in flipArt(signal) }
        } else {
            innerContent
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.thickMaterial)
                        // Forced dark so the material stays a dark frosted look
                        // regardless of system appearance, matching the lock
                        // screen's always-dark iOS 18-style now-playing card.
                        .environment(\.colorScheme, .dark)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
                .onChange(of: musicManager.artFlipSignal) { _, signal in flipArt(signal) }
        }
    }

    @ViewBuilder
    private var innerContent: some View {
        // Always centered — the top row's own HStack (below) is already
        // full-width/flexible so this doesn't move it, but MusicSlotToolbar
        // and the progress bar aren't, so a .leading guide here was pinning
        // them to the left instead of letting them center in the 320pt card.
        VStack(alignment: .center, spacing: 0) {
            // ── Top row ──
            HStack(alignment: .center, spacing: 12) {
                if !isExpanded { albumArtThumbnail }
                VStack(alignment: isExpanded ? .center : .leading, spacing: 3) {
                    MarqueeText(
                        .constant(musicManager.songTitle.isEmpty ? "Not Playing" : musicManager.songTitle),
                        font: .headline,
                        nsFont: .headline,
                        textColor: .white,
                        // Narrower than the row's own available space so the
                        // box (and its trailing edge fade) clears the waveform
                        // overlay instead of running under it.
                        frameWidth: isExpanded ? 210 : 190,
                        trailingIcon: musicManager.isExplicitTrack ? "e.square.fill" : nil,
                        trailingIconColor: Color(white: 0.55),
                        centerWhenFits: isExpanded
                    )
                    .fontWeight(.semibold)
                    // MarqueeText's internal GeometryReader always fills whatever
                    // width its parent proposes rather than clamping to
                    // frameWidth itself — without this, the .frame(maxWidth:
                    // .infinity) below hands it the full row width, and the
                    // correctly-centered content inside ends up pinned to the
                    // left edge of that (rather than actually centered in the row).
                    .frame(width: isExpanded ? 210 : 190)
                    .edgeFade(trailing: 6)
                    MarqueeText(
                        .constant(musicManager.artistName.isEmpty ? "—" : musicManager.artistName),
                        font: .subheadline,
                        nsFont: .subheadline,
                        textColor: playerColorTinting
                            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
                            : Color.white.opacity(0.65),
                        frameWidth: isExpanded ? 210 : 190,
                        centerWhenFits: isExpanded
                    )
                    .fontWeight(.medium)
                    .frame(width: isExpanded ? 210 : 190)
                    .edgeFade(trailing: 6)
                }
                // Alignment spelled out explicitly (rather than relying on
                // default .center) so the text stays pinned leading in the
                // collapsed row regardless of how much space this flexible
                // frame is handed — needed now that the waveform below is an
                // always-present overlay rather than a same-row sibling
                // competing for space via a Spacer.
                .frame(maxWidth: .infinity, alignment: isExpanded ? .center : .leading)
            }
            .padding(.horizontal, isExpanded ? 14 : 12)
            .padding(.top, isExpanded ? 16 : 14)
            .overlay(alignment: .trailing) {
                // A single persistent view (not conditionally inserted per
                // state) so its position — trailing inset and vertical offset
                // — animates smoothly between collapsed/expanded instead of
                // snapping via an insert/remove swap.
                audioSpectrum
                    .padding(.trailing, isExpanded ? 14 : 12)
                    .offset(y: 5)
            }

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
                    inlineTimestamps: true,
                    isLive: musicManager.isLiveBrowserStream
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
            .padding(.top, isExpanded ? 0 : 4)

            // ── Transport controls ──
            MusicSlotToolbar(isLockScreenContext: true)
                .padding(.bottom, 8)
        }
        .frame(width: 320)
    }

    private func flipArt(_ signal: ArtFlipSignal) {
        let dir: Double = signal.direction == .forward ? 1 : -1
        withAnimation(.easeIn(duration: 0.22)) {
            rotationDegrees = dir * 90
            flipBlur = 4
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            displayedArt = signal.art
            rotationDegrees = dir * -90
            flipBrightness = 0.6
            withAnimation(.easeOut(duration: 0.22)) {
                rotationDegrees = 0
                flipBlur = 0
                flipBrightness = 0
            }
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

    private var audioSpectrum: some View {
        AudioSpectrumView(isPlaying: $musicManager.isPlaying)
            .frame(width: AudioSpectrum.recommendedFrameSize.width, height: AudioSpectrum.recommendedFrameSize.height)
            .colorMultiply(.white)
            .opacity(0.50)
            .fixedSize()
            .padding(.trailing, 4)
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
            .rotation3DEffect(.degrees(rotationDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .blur(radius: flipBlur)
            .brightness(flipBrightness)
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            // Shrinks + fades in place on expand, rather than morphing into the
            // expanded position — the expanded view fades/scales in separately
            // (LiquidGlassWidgetRoot), so these are two independent transitions.
            // Both scale and opacity get their own fast, explicit animation
            // rather than riding the ambient spring — the card itself also
            // slides down as part of that same spring (the root's bottom
            // Spacer shrinks on expand), and letting the thumbnail's shrink
            // stretch across that whole slower transaction was what made it
            // look like the art was drifting downward as it shrank; finishing
            // quickly, before the card has moved far, avoids that.
            .transition(.scale(scale: 0.35, anchor: .center).animation(.easeOut(duration: 0.22)).combined(with: .opacity.animation(.easeOut(duration: 0.22))))
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
