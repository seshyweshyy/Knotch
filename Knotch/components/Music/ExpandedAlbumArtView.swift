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
        Image(nsImage: displayedArt)
            .resizable()
            .aspectRatio(1, contentMode: .fill)
            .matchedGeometryEffect(id: "albumArt", in: artNamespace)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    isExpanded = false
                }
            }
            .onChange(of: musicManager.artFlipSignal) { _, signal in
                displayedArt = signal.art
            }
    }
}
