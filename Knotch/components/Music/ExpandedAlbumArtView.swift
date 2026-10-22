//
//  ExpandedAlbumArtView.swift
//  Knotch
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
    @State private var incomingArt: NSImage? = nil
    @State private var incomingOpacity: Double = 0
    @State private var artGeneration = 0
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    var body: some View {
        ZStack {
            // Outgoing art — always visible underneath
            Image(nsImage: displayedArt)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .matchedGeometryEffect(id: "albumArt", in: artNamespace)

            // Incoming art — fades in on top, then becomes the new base
            if let incoming = incomingArt {
                Image(nsImage: incoming)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(incomingOpacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                isExpanded = false
            }
        }
        .onChange(of: musicManager.artFlipSignal) { _, signal in
            artGeneration += 1
            let generation = artGeneration
            incomingArt = signal.art
            incomingOpacity = 0
            withAnimation(.easeInOut(duration: 0.4), completionCriteria: .removed) {
                incomingOpacity = 1
            } completion: {
                guard generation == artGeneration else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayedArt = signal.art
                    incomingArt = nil
                    incomingOpacity = 0
                }
            }
        }
    }
}
