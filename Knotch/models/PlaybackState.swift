//
//  PlaybackState.swift
//  Knotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation

enum RepeatMode: Int, Codable {
    case off = 1
    case one = 2
    case all = 3
}

struct PlaybackState {
    var bundleIdentifier: String
    var isPlaying: Bool = false
    var title: String = "Not Playing"
    var artist: String = "Unknown"
    var album: String = "Unknown"
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    var lastUpdated: Date = Date.distantPast
    var artwork: Data?
    var volume: Double = 0.5
    var isFavorite: Bool = false
    var isExplicit: Bool = false
    // True for a podcast/audiobook episode rather than a music track — drives
    // whether speed control is enabled and which sneak-peek icon shows.
    // Only ever set true by SpotifyController (spotify:episode: URI) and
    // NowPlayingController (bundleIdentifier == com.apple.podcasts); every
    // other controller only ever serves music, so it defaults correctly.
    var isPodcastContent: Bool = false
    // Apple Music's public catalog track ID (MediaRemote's "uniqueIdentifier"),
    // only trusted when bundleIdentifier is com.apple.Music — used to look up
    // motion artwork and audio quality (lossless/Dolby Atmos) without a fuzzy
    // title/artist search.
    var appleMusicTrackID: Int?
}

extension PlaybackState: Equatable {
    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.isPlaying == rhs.isPlaying
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.currentTime == rhs.currentTime
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.artwork == rhs.artwork
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isExplicit == rhs.isExplicit
    }
}
