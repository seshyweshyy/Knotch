//
//  NotchHomeView.swift
//  Knotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import AppKit
import Combine
import Defaults
import SwiftUI
import CoreAudio

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: KnotchViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        HStack {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                .padding(.all, 5)
            MusicControlsWithVisualizer()
        }
    }
}

private struct MusicControlsWithVisualizer: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.homeViewVisualizer) private var homeViewVisualizer

    // Width the visualizer occupies — passed to MusicControlsView to shrink marquee text
    private let visualizerReservedWidth: CGFloat = 42

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MusicControlsView(trailingReserve: homeViewVisualizer && musicManager.isPlaying ? visualizerReservedWidth : 0)
                .drawingGroup()
                .compositingGroup()

            if homeViewVisualizer && musicManager.isPlaying {
                AlbumArtWaveformMask(albumArt: musicManager.albumArt, isPlaying: .constant(musicManager.isPlaying))
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    .padding(.trailing, 4)
                    .padding(.top, 16)
            }
        }
        // The preference reader that turns this into a real anchor view lives on
        // NotchHomeView, not here — compact mode's AudioOutputButton (inside
        // CompactMusicPlayerView) never renders this view at all, so a reader
        // scoped to just this one would leave compact mode's anchor never set.
    }
}

// MARK: - Audio Output Button anchor plumbing
//
// See MusicControlsWithVisualizer's `.overlayPreferenceValue` for why this
// exists: AudioOutputButton reports its frame via preference from inside a
// `.drawingGroup()`'d branch (safe — GeometryReader is pure layout, unaffected
// by rasterization), and the real anchor NSView is planted outside that branch,
// positioned to match.

private let audioOutputAnchorSpaceName = "audioOutputAnchorSpace"

private struct AudioOutputAnchorFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

// Holds the live anchor NSView so AudioOutputButton can read its real,
// AppKit-native screen frame at tap time — no manual coordinate-space math.
@MainActor
final class AudioOutputAnchorHolder {
    static let shared = AudioOutputAnchorHolder()
    private init() {}
    weak var view: NSView?
}

// hitTest returns nil so this is purely a geometry probe, never a target for
// any mouse event (a hit-testable view here previously stole clicks meant for
// the toggle button, seen live as a drag-prohibited cursor instead of a tap).
private final class ClickThroughProbeNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct AudioOutputAnchorProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughProbeNSView(frame: .zero)
        AudioOutputAnchorHolder.shared.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        AudioOutputAnchorHolder.shared.view = nsView
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: KnotchViewModel
    let albumArtNamespace: Namespace.ID
    var size: CGFloat = 132
    // How dark the paused overlay on albumArtImage goes when paused.
    var pausedFadeOpacity: CGFloat = 0.3
    // Multiplies the corner radius so callers can round the art a bit less
    // (or more) than the standard home view without touching the shared
    // MusicPlayerImageSizes values every other consumer relies on.
    var cornerRadiusScale: CGFloat = 0.85

    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var rotationDegrees: Double = 0
    @State private var flipBlur: CGFloat = 0
    @State private var flipBrightness: Double = 0

    // The placeholder icon has no "playing"/"paused" state of its own to
    // reflect — shrinking/dimming it in step with isPlaying would just read
    // as the icon itself flickering for no reason.
    private var showsPausedLook: Bool {
        !musicManager.isPlaying && displayedArt !== noArtworkPlaceholderImage
    }

    private var activeCornerRadius: CGFloat {
        (vm.notchState == .open
            ? MusicPlayerImageSizes.cornerRadiusInset.opened
            : MusicPlayerImageSizes.cornerRadiusInset.closed) * cornerRadiusScale
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
        // Fixed size independent of ambient layout proposals, so the liquid pull
        // (or anything else that briefly offers more space) can never resize this —
        // it previously filled whatever height it was given and clipped on the notch's
        // rounded corner during a hard pull.
        .frame(width: size, height: size)
        // Explicit, so the art's shrink/fade always plays out at this pace
        // regardless of whatever (often much faster) animation duration wraps
        // the isPlaying change at the call site — e.g. the play/pause icon's
        // own snappy transition — instead of snapping in lockstep with it.
        // Keyed on showsPausedLook rather than isPlaying directly so it also
        // animates the placeholder-art edge case (e.g. a paused track's real
        // art arriving after the placeholder was showing).
        .animation(.smooth(duration: 0.35), value: showsPausedLook)
    }
    
    @State private var blurredArt: NSImage = MusicManager.shared.albumArt
    private var albumArtBackground: some View {
        Image(nsImage: blurredArt)
            .resizable()
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: activeCornerRadius))
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
            .onChange(of: musicManager.artFlipSignal) { _, signal in
                blurredArt = signal.art
            }
    }

    private var albumArtButton: some View {
        Button {
            musicManager.openMusicApp()
        } label: {
            ZStack(alignment:.bottomTrailing) {
                albumArtImage
                appIconOverlay
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(showsPausedLook ? 0.90 : 1)
    }

    private var albumArtImage: some View {
        Image(nsImage: displayedArt)
            .resizable()
            // Wide artwork (e.g. YouTube video thumbnails) has its own aspect
            // ratio, not 1:1 — scale to fit so the whole thumbnail stays
            // visible (letterboxed) instead of being cropped or squashed.
            .scaledToFit()
            // Round the letterboxed thumbnail itself, not just the square
            // frame around it — otherwise non-square art keeps sharp
            // corners since it no longer touches the frame's edges.
            .clipShape(RoundedRectangle(cornerRadius: activeCornerRadius / 2))
            // Overlay (rather than a same-size sibling shape) so the paused
            // dim always matches the image's own resolved bounds — a plain
            // square sibling stuck out past non-square (e.g. YouTube
            // thumbnail) art as a visible box once it no longer had the old
            // blur to hide the mismatch.
            .overlay(
                RoundedRectangle(cornerRadius: activeCornerRadius / 2)
                    .foregroundColor(.black)
                    .opacity(showsPausedLook ? pausedFadeOpacity : 0)
                    .allowsHitTesting(false)
            )
            .frame(width: size, height: size)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: activeCornerRadius))
            .rotation3DEffect(
                .degrees(rotationDegrees),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.4
            )
            .blur(radius: flipBlur)
            .brightness(flipBrightness)
            .onChange(of: musicManager.artFlipSignal) { _, signal in
                let dir: Double = signal.direction == .forward ? 1 : -1

                withAnimation(.easeIn(duration: 0.22)) {
                    rotationDegrees = dir * 90
                    flipBlur = 4
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    displayedArt = signal.art
                    rotationDegrees = dir * -90
                    // Snap the flash on at the swap so it reads as a flick of
                    // light off the new art's edge, not a fade-in.
                    flipBrightness = 0.6
                    withAnimation(.easeOut(duration: 0.22)) {
                        rotationDegrees = 0
                        flipBlur = 0
                        flipBrightness = 0
                    }
                }
            }
    }
    
    @ViewBuilder
    private var appIconOverlay: some View {
        // Compact mode's smaller album art has no room for this overlay.
        if vm.notchState == .open && rotationDegrees == 0 && !Defaults[.enableCompactUI] && Defaults[.showAppIconOnAlbumArt] {
            AppIcon(for: musicManager.bundleIdentifier ?? Defaults[.defaultPlayer].bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    var trailingReserve: CGFloat = 0
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        VStack(alignment: .leading) {
            songInfoAndSlider
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                songInfo(width: geo.size.width)
                musicSlider
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    musicManager.openMusicApp()
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        BlurRevealText(musicManager.songTitle) { title in
                            MarqueeText(
                                .constant(title),
                                font: .headline,
                                nsFont: .headline,
                                textColor: .white,
                                frameWidth: width - trailingReserve,
                                trailingIcon: musicManager.isExplicitTrack ? "e.square.fill" : nil,
                                trailingIconColor: Color(white: 0.55)
                            )
                            .edgeFade()
                        }
                        BlurRevealText(musicManager.artistName) { artist in
                            MarqueeText(
                                .constant(artist),
                                font: .headline,
                                nsFont: .headline,
                                textColor: Defaults[.playerColorTinting]
                                    ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
                                    : .gray,
                                frameWidth: width - trailingReserve
                            )
                            .fontWeight(.medium)
                            .edgeFade()
                        }
                    }
                }
                .buttonStyle(.plain)

                if Defaults[.enableLyrics] {
                    TimelineView(.animation(minimumInterval: 0.25, paused: !musicManager.isPlaying)) { timeline in
                        let currentElapsed: Double = {
                            guard musicManager.isPlaying else { return musicManager.elapsedTime }
                            let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                            let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                            return min(max(progressed, 0), musicManager.songDuration)
                        }()
                        let line: String = {
                            if musicManager.isFetchingLyrics { return "Loading lyrics…" }
                            if !musicManager.syncedLyrics.isEmpty {
                                return musicManager.lyricLine(at: currentElapsed)
                            }
                            let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                            return trimmed.isEmpty ? "No lyrics found" : trimmed.replacingOccurrences(of: "\n", with: " ")
                        }()
                        let isPersian = line.unicodeScalars.contains { scalar in
                            let v = scalar.value
                            return v >= 0x0600 && v <= 0x06FF
                        }
                        MarqueeText(
                            .constant(line),
                            font: .subheadline,
                            nsFont: .subheadline,
                            textColor: musicManager.isFetchingLyrics ? .gray.opacity(0.7) : .gray,
                            frameWidth: width
                        )
                        .font(isPersian ? .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize) : .subheadline)
                        .lineLimit(1)
                        .opacity(musicManager.isPlaying ? 1 : 0)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }

    private var musicSlider: some View {
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
                isLive: musicManager.isLiveBrowserStream
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 5)
            .frame(height: 36)
        }
    }

    private var slotToolbar: some View {
        MusicSlotToolbar()
            .frame(maxWidth: .infinity, alignment: .center)
    }

}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    // Apple Music's own "favorite" action is a star, not a heart (Spotify's
    // is a heart) — matching each app's own iconography rather than always
    // showing one shape.
    private var iconName: String {
        let isAppleMusic = musicManager.bundleIdentifier == MediaControllerType.appleMusic.bundleIdentifier
        if isAppleMusic {
            return musicManager.isFavoriteTrack ? "star.fill" : "star"
        }
        return musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? Color(nsColor: musicManager.avgColor) : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Audio Output Button

struct AudioOutputButton: View {
    @ObservedObject private var routeManager = AudioRouteManager.shared
    @StateObject private var volumeModel = MediaOutputVolumeViewModel()
    @State private var isPopoverPresented = false
    @EnvironmentObject var vm: KnotchViewModel

    private var buttonIcon: String {
        routeManager.activeDevice?.iconName ?? "speaker.wave.2"
    }

    var body: some View {
        HoverButton(icon: buttonIcon, scale: .medium) {
            isPopoverPresented.toggle()
            if isPopoverPresented {
                routeManager.refreshDevices()
            }
        }
        // Reports this button's frame for NotchHomeView's real anchor probe to
        // track — see its `.overlayPreferenceValue` for why the probe lives
        // there instead of directly here.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: AudioOutputAnchorFrameKey.self,
                    value: geo.frame(in: .named(audioOutputAnchorSpaceName))
                )
            }
        )
        // Custom window-based popover instead of `.popover()` — see
        // MediaOutputPopoverWindowManager for why.
        .onChange(of: isPopoverPresented) { _, presented in
            vm.isMediaOutputPopoverActive = presented
            if presented {
                guard let anchorView = AudioOutputAnchorHolder.shared.view,
                      let window = anchorView.window else { return }
                let anchorFrameOnScreen = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
                MediaOutputPopoverWindowManager.shared.show(
                    anchorFrameOnScreen: anchorFrameOnScreen,
                    routeManager: routeManager,
                    volumeModel: volumeModel,
                    onDismiss: { isPopoverPresented = false }
                )
            } else {
                MediaOutputPopoverWindowManager.shared.hide()
            }
        }
        // Follows vm.isMediaOutputPopoverActive being forced false from outside
        // this view (e.g. KnotchViewModel.close()) so the custom panel tears down too.
        .onChange(of: vm.isMediaOutputPopoverActive) { _, active in
            if !active {
                isPopoverPresented = false
            }
        }
        .onDisappear {
            vm.isMediaOutputPopoverActive = false
            isPopoverPresented = false
            MediaOutputPopoverWindowManager.shared.hide()
        }
    }
}

// MARK: - Lock Screen Audio Output Indicator (icon only, not interactive)
//
// The lock-screen widget lives in a non-activating panel that never becomes
// key (loginwindow keeps focus), so a real AppKit `.popover` window spawned
// from it never receives continued mouseDragged events — the volume-drag
// pill inside MediaOutputSelectorPopover is untouchable there, and an inline
// picker turned out to be unreliable to size correctly. This just shows the
// current output's icon; tapping does nothing.
struct LockScreenAudioOutputIndicator: View {
    @ObservedObject private var routeManager = AudioRouteManager.shared

    private var buttonIcon: String {
        routeManager.activeDevice?.iconName ?? "speaker.wave.2"
    }

    var body: some View {
        // No Button/HoverButton wrapper — this is a static icon, not a
        // control, so it shouldn't show hover fill or a pressed state
        // that would suggest it does something.
        Image(systemName: buttonIcon)
            .foregroundColor(.primary)
            .font(.title2)
            .frame(width: 40, height: 40)
            .onAppear {
                routeManager.refreshDevices()
            }
    }
}

// MARK: - Media Output Selector Popover

struct MediaOutputSelectorPopover: View {
    @ObservedObject var routeManager: AudioRouteManager
    @ObservedObject var volumeModel: MediaOutputVolumeViewModel
    var onHoverChanged: (Bool) -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            devicesSection
        }
        .frame(width: 255)
        .padding(16)
        .onHover { onHoverChanged($0) }
        .onDisappear { onHoverChanged(false) }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output devices")
                .font(.caption)
                .foregroundColor(.secondary)

            if routeManager.devices.isEmpty {
                Text("No audio outputs available")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if routeManager.devices.count > 5 {
                // Only pay for a ScrollView once there are enough rows to
                // actually need scrolling — otherwise it claims height up to
                // the cap even when the content is much shorter.
                ScrollView {
                    deviceRows
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 220)
            } else {
                deviceRows
            }
        }
    }

    private var deviceRows: some View {
        VStack(spacing: 6) {
            ForEach(routeManager.devices) { device in
                AudioDeviceRow(
                    device: device,
                    isSelected: device.id == routeManager.activeDeviceID,
                    routeManager: routeManager,
                    volumeModel: volumeModel,
                    dismiss: dismiss
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Audio Device Row (selected row doubles as a volume slider, like iOS AirPlay picker)

struct AudioDeviceRow: View {
    let device: AudioOutputDevice
    let isSelected: Bool
    @ObservedObject var routeManager: AudioRouteManager
    @ObservedObject var volumeModel: MediaOutputVolumeViewModel
    var dismiss: () -> Void

    @State private var rowWidth: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.iconName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 22)
                .foregroundColor(isSelected ? .black : .primary)
            Text(device.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isSelected ? .black : .primary)
                .lineLimit(1)
            Spacer()
            if isSelected {
                ZStack {
                    if isDragging {
                        VolumeHUDLottieView(value: CGFloat(volumeModel.level), displaySize: 18)
                            .colorInvert()
                            .scaleEffect(1.4)
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black)
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
                .frame(width: 18, height: 18)
                .animation(.easeOut(duration: 0.15), value: isDragging)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(isSelected ? 0.28 : 0)
                    if isSelected {
                        Rectangle()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: max(0, geo.size.width * CGFloat(volumeModel.level)))
                    }
                }
                .background(isSelected ? Color.clear : Color.secondary.opacity(0.14))
                .onAppear { rowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newValue in rowWidth = newValue }
            }
            .clipShape(Capsule(style: .continuous))
        )
        .contentShape(Capsule(style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isSelected, rowWidth > 0 else { return }
                    isDragging = true
                    let fraction = min(max(value.location.x / rowWidth, 0), 1)
                    volumeModel.setVolume(Float(fraction))
                }
                .onEnded { _ in
                    isDragging = false
                    if !isSelected {
                        routeManager.select(device: device)
                        dismiss()
                    }
                }
        )
    }
}

struct MusicSlotToolbar: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.musicControlSlots) private var slotConfig

    // The lock-screen widget shows a non-interactive icon for the audio output slot instead of the popover (see LockScreenAudioOutputIndicator).
    var isLockScreenContext: Bool = false
    var spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: spacing) {
            Spacer()
            ForEach(Array(activeSlots.enumerated()), id: \.offset) { _, slot in
                slotView(for: slot)
            }
            Spacer()
        }
    }

    private var activeSlots: [MusicControlButton] {
        let limit = min(max(MusicControlButton.minSlotCount, slotConfig.count), MusicControlButton.maxSlotCount)
        return Array(slotConfig.padded(to: limit, filler: .none).prefix(limit))
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        Group {
            switch slot {
            case .shuffle:
                HoverButton(icon: "shuffle", scale: .medium, activeDot: musicManager.isShuffled) {
                    MusicManager.shared.toggleShuffle()
                }
            case .previous:
                HoverButton(
                    icon: "backward.fill", scale: .medium, iconScale: 0.9, animateOnTap: true,
                    externalAnimationEvent: .previousTrackSkip,
                    pushProgress: musicManager.horizontalGestureSkipDirection == .backward ? musicManager.horizontalGestureProgress : 0
                ) {
                    MusicManager.shared.previousTrack()
                }
            case .playPause:
                HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                    MusicManager.shared.togglePlay()
                }
            case .next:
                HoverButton(
                    icon: "forward.fill", scale: .medium, iconScale: 0.9, animateOnTap: true,
                    externalAnimationEvent: .nextTrackSkip,
                    pushProgress: musicManager.horizontalGestureSkipDirection == .forward ? musicManager.horizontalGestureProgress : 0
                ) {
                    MusicManager.shared.nextTrack()
                }
            case .repeatMode:
                HoverButton(icon: repeatIcon, scale: .medium, activeDot: musicManager.repeatMode != .off, activeDotXOffset: 0, liftsIconWhenDotActive: true, hapticStateKey: musicManager.repeatMode.rawValue) {
                    MusicManager.shared.toggleRepeat()
                }
            case .volume:
                VolumeControlView()
            case .favorite:
                FavoriteControlButton()
            case .goBackward:
                HoverButton(icon: "gobackward.15", scale: .medium) {
                    MusicManager.shared.skip(seconds: -15)
                }
            case .goForward:
                HoverButton(icon: "goforward.15", scale: .medium) {
                    MusicManager.shared.skip(seconds: 15)
                }
            case .audioOutput:
                if isLockScreenContext {
                    LockScreenAudioOutputIndicator()
                } else {
                    AudioOutputButton()
                }
            case .none:
                Color.clear.frame(width: 40, height: 1)
            }
        }
        // While a horizontal skip-media gesture is live, dim every button except
        // the one about to fire, so only that skip direction reads as the focus.
        .opacity(isActiveSkipSlot(slot) ? 1 : dimmedSlotOpacity)
        .animation(.easeOut(duration: 0.2), value: musicManager.horizontalGestureProgress)
    }

    private func isActiveSkipSlot(_ slot: MusicControlButton) -> Bool {
        switch (slot, musicManager.horizontalGestureSkipDirection) {
        case (.previous, .backward), (.next, .forward): return true
        default: return false
        }
    }

    private var dimmedSlotOpacity: Double {
        guard musicManager.horizontalGestureSkipDirection != nil else { return 1 }
        return 1 - (0.55 * musicManager.horizontalGestureProgress)
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}
// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @ObservedObject var timerManager = TimerManager.shared
    // Observed so Compact mode's tray/converter pages reactively appear and
    // disappear as their underlying state changes, instead of only updating
    // on the next unrelated re-render.
    @ObservedObject var trayState = TrayStateViewModel.shared
    @ObservedObject var fileConverterState = FileConverterViewModel.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                if timerManager.isCreatingTimer {
                    TimerSliderView()
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                } else {
                    mainContent
                }
            }
        }
        .frame(maxWidth: .infinity)
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
        .onChange(of: timerManager.isCreatingTimer) { _, isCreating in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                vm.notchSize = isCreating
                    ? CGSize(width: WidgetWidth.timerSlider, height: vm.notchSize.height)
                    : vm.computedHomeSize
            }
        }
        .coordinateSpace(name: audioOutputAnchorSpaceName)
        // Common to both compactContent and standardContent, so AudioOutputButton's
        // real anchor probe gets placed regardless of which one is showing — see
        // AudioOutputAnchorProbe's comment for why it can't just live at the
        // button's own position inside standard mode's `.drawingGroup()`.
        .overlayPreferenceValue(AudioOutputAnchorFrameKey.self) { frame in
            if frame != .zero {
                AudioOutputAnchorProbe()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    @ViewBuilder
    private var mainContent: some View {
        if Defaults[.enableCompactUI] {
            compactContent
        } else {
            standardContent
        }
    }

    private var compactContent: some View {
        Group {
            if vm.isCompactDragOverlayActive {
                // Transient live-activity overlay — morphs whatever page was
                // showing into a drop target for the duration of the drag,
                // using a "squish and blur" pop instead of the plain slide
                // the page swaps below use.
                CompactTrayDropZoneView()
                    .transition(.liveActivityPop)
            } else {
                switch vm.resolvedCompactPage {
                case .tray:
                    CompactTrayView()
                        .transition(compactViewTransition)
                case .converter:
                    // Reveals straight out of the drop-zone overlay, whose own
                    // exit already uses .liveActivityPop — matching it here
                    // instead of compactViewTransition's move-based swap keeps
                    // that handoff one continuous blur/scale instead of a
                    // squish-then-slide mismatch.
                    CompactFileConverterView()
                        .transition(.liveActivityPop)
                case .calendar:
                    CompactCalendarView()
                        .transition(compactViewTransition)
                case .music:
                    CompactMusicPlayerView(albumArtNamespace: albumArtNamespace)
                        .transition(compactViewTransition)
                }
            }
        }
        .animation(liveActivityPopSpring, value: vm.isCompactDragOverlayActive)
        .animation(.smooth(duration: 0.35), value: vm.resolvedCompactPage)
        // Same liquid stretch the standard widgets get, riding the drag before
        // the swap commits — already comes out toned down here since compact
        // mode clamps liquidPull itself to 0.4x during the gesture.
        .liquidStretch(vm)
    }

    // Old content slides up and out while new content slides up into place —
    // matches the direction of the swipe-down gesture that triggers the swap.
    private var compactViewTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .blur(radius: 30)),
            removal: .move(edge: .top).combined(with: .opacity).combined(with: .blur(radius: 30))
        )
    }

    private var standardContent: some View {
        let showMusic = coordinator.musicLiveActivityEnabled
        let showCal = Defaults[.showCalendar]
        let showCam = shouldShowCamera

        return HStack(alignment: .top, spacing: WidgetWidth.spacing) {
            if showMusic {
                MusicPlayerView(albumArtNamespace: albumArtNamespace)
                    .frame(width: WidgetWidth.music)
            }
            if showCal {
                if showMusic {
                    Divider()
                }
                CalendarView()
                    .frame(width: showCam ? WidgetWidth.calendarWithCam : WidgetWidth.calendar)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(
                        StableHoverTracker { isHovering in
                            vm.isHoveringCalendar = isHovering
                        }
                    )
                    .environmentObject(vm)
                    .transition(.opacity)
            }
            if showCam {
                if showCal || showMusic {
                    Divider()
                }
                CameraPreviewView(webcamManager: webcamManager)
                    .frame(width: WidgetWidth.camera)
                    .scaledToFit()
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Single stretch for the whole row, anchored to its own top — matches
        // compactContent so all widgets move together instead of drifting
        // apart (each used to stretch from its own local top edge).
        .liquidStretch(vm)
    }
}

private func audioOutputIcon() -> String {
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size, &deviceID)
    guard deviceID != kAudioObjectUnknown else { return "hifispeaker.fill" }

    var transportType: UInt32 = 0
    var transportAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transportSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transportType)

    switch transportType {
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>? = nil
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef)
        let name = nameRef?.takeRetainedValue() as String? ?? ""
        if name.localizedCaseInsensitiveContains("AirPods Max") {
            return "airpodsmax"
        } else if name.localizedCaseInsensitiveContains("AirPods Pro") {
            return "airpodspro"
        } else if name.localizedCaseInsensitiveContains("AirPods") {
            return "airpods"
        } else {
            return "headphones"
        }
    case kAudioDeviceTransportTypeUSB:
        return "speaker.fill"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
        return "tv.fill"
    case kAudioDeviceTransportTypeBuiltIn:
        return "laptopcomputer"
    default:
        return "hifispeaker.fill"
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var showRemainingTime: Bool = false
    var inlineTimestamps: Bool = false
    /// True for a browser tab with no known duration — nothing to scrub, so show a
    /// static "LIVE" bar instead of a progress track stuck at 0%.
    var isLive: Bool = false
    var onValueChange: (Double) -> Void

    var body: some View {
        if isLive {
            liveIndicatorBar
        } else if inlineTimestamps {
            HStack(alignment: .center, spacing: 6) {
                Text(timeString(from: sliderValue))
                    .fontWeight(.medium)
                    .foregroundColor(
                        Defaults[.playerColorTinting]
                            ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
                    )
                    .font(.caption)
                    .monospacedDigit()
                    .fixedSize()

                CustomSlider(
                    value: $sliderValue,
                    range: 0...duration,
                    color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                        ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                        : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                    dragging: $dragging,
                    lastDragged: $lastDragged,
                    onValueChange: onValueChange
                )
                .frame(height: 10, alignment: .center)

                Text(showRemainingTime
                     ? "-" + timeString(from: max(0, duration - sliderValue))
                     : timeString(from: duration))
                    .fontWeight(.medium)
                    .foregroundColor(
                        Defaults[.playerColorTinting]
                            ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
                    )
                    .font(.caption)
                    .monospacedDigit()
                    .fixedSize()
            }
            .onAppear {
                let target = MusicManager.shared.estimatedPlaybackPosition(at: Date())
                withAnimation(.easeOut(duration: 0.4)) { sliderValue = target }
            }
            .onChange(of: currentDate) {
                guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
                sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
            }
        } else {
            VStack {
                CustomSlider(
                    value: $sliderValue,
                    range: 0...duration,
                    color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                        ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                        : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                    dragging: $dragging,
                    lastDragged: $lastDragged,
                    onValueChange: onValueChange
                )
                .frame(height: 10, alignment: .center)

                HStack {
                    Text(timeString(from: sliderValue))
                    Spacer()
                    if showRemainingTime {
                        Text("-" + timeString(from: max(0, duration - sliderValue)))
                    } else {
                        Text(timeString(from: duration))
                    }
                }
                .fontWeight(.medium)
                .foregroundColor(
                    Defaults[.playerColorTinting]
                        ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
                )
                .font(.caption)
            }
            .onAppear {
                let target = MusicManager.shared.estimatedPlaybackPosition(at: Date())
                withAnimation(.easeOut(duration: 0.4)) { sliderValue = target }
            }
            .onChange(of: currentDate) {
                guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
                sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
            }
        }
    }

    private var liveIndicatorBar: some View {
        ZStack {
            Capsule()
                .fill(.gray.opacity(0.3))
                .frame(height: 5)
            // Same technique as the timer ruler's edge fade: fill with the
            // notch's actual background color and alpha-mask it, rather than
            // baking opacity into the gradient itself — keeps the patch
            // reading as the real background instead of a translucent smudge
            // on top of it. Single peak at the center, no flat plateau, so
            // it's a continuous fade the whole way across rather than a
            // solid block with fades only at its edges.
            Rectangle()
                .fill(Color.black)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.5),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 70, height: 14)
                .allowsHitTesting(false)
            Text("LIVE")
                .font(.caption2)
                .fontWeight(.semibold)
                .tracking(1.5)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
            // Ticks arrive every 0.5s from the parent TimelineView; animating the
            // fill linearly over that same interval turns the once-per-tick jump
            // into continuous motion instead of a snap. Skipped while dragging so
            // the thumb tracks the cursor immediately.
            //
            // Keyed on filledTrackWidth (not just value) so a width change from
            // an ancestor's own animation (e.g. the lock-screen widget's expand/
            // collapse spring resizing this view's container) also falls inside
            // this animation's tracked scope — otherwise .animation(value:)
            // silently opts everything BUT `value` changes out of animating at
            // all, so a width-only change snapped instantly instead of easing,
            // which read as the fill flashing/disappearing mid-transition.
            .animation(dragging ? nil : .linear(duration: 0.5), value: filledTrackWidth)
        }
    }
}
