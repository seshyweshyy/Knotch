//
//  ExpandedAlbumArtView.swift
//  boringNotch
//
//  Full-screen expanded album art overlay shown when the thumbnail is tapped
//  on the lock screen widget. Matches the iOS lock screen expanded player style.
//

import SwiftUI
import Defaults

struct ExpandedAlbumArtView: View {
    @Binding var isExpanded: Bool
    var artNamespace: Namespace.ID

    @ObservedObject var musicManager = MusicManager.shared
    @Default(.playerColorTinting) var playerColorTinting

    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    var body: some View {
        ZStack {
            // Blurred album art background (fills screen, tinted dark)
            Image(nsImage: displayedArt)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 60)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Dismiss button (top-left X, like iOS)
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            isExpanded = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 24)
                    .padding(.top, 24)
                    Spacer()
                }

                Spacer()

                // Large album art — matched geometry from thumbnail
                Image(nsImage: displayedArt)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .matchedGeometryEffect(id: "albumArt", in: artNamespace)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 20)
                    .padding(.horizontal, 40)

                Spacer().frame(height: 32)

                // Song title + artist
                VStack(spacing: 6) {
                    Text(musicManager.songTitle.isEmpty ? "Not Playing" : musicManager.songTitle)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)

                    Text(musicManager.artistName.isEmpty ? "—" : musicManager.artistName)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(.horizontal, 40)

                Spacer().frame(height: 24)

                // Progress bar
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
                        isPlaying: musicManager.isPlaying
                    ) { newValue in
                        MusicManager.shared.seek(to: newValue)
                    }
                    .frame(height: 36)
                    .colorMultiply(.white)
                }
                .padding(.horizontal, 32)

                // Transport controls
                MusicSlotToolbar()
                    .padding(.bottom, 16)
            }
        }
        .onChange(of: musicManager.artFlipSignal) { _, signal in
            displayedArt = signal.art
        }
    }
}
