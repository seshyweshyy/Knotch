//
//  SpotifyController.swift
//  Knotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

class SpotifyController: MediaControllerProtocol {
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.spotify.client"
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    // spotify_cli only exists on Spotify builds recent enough to ship it —
    // reflect that dynamically rather than hardcoding true, so older installs
    // fall back to no favorite support instead of silently no-oping.
    var supportsFavorite: Bool { spotifyCLIURL != nil }
    var supportsSpeedControl: Bool { spotifyCLIURL != nil }

    private var notificationTask: Task<Void, Never>?

    // Constant for time between command and update
    private let commandUpdateDelay: Duration = .milliseconds(25)

    private var lastArtworkURL: String?
    private var artworkFetchTask: Task<Void, Never>?

    // Resolved once — Spotify.app's own install location, not assumed to be
    // /Applications. nil means this Spotify build predates spotify_cli.
    private lazy var spotifyCLIURL: URL? = Self.resolveSpotifyCLI()

    // AppleScript's "repeating" is a Boolean, so it can't distinguish repeat-one
    // from repeat-all. Whenever *we* set the mode via spotify_cli we know the
    // exact resulting state; that's carried forward here and trusted over the
    // Boolean for as long as repeating stays true. If repeat was last changed
    // directly in Spotify's own UI (not through Knotch), this falls back to
    // guessing .all, same as before spotify_cli existed.
    private var lastKnownRepeatMode: RepeatMode = .off

    // spotify_cli's "speed" isn't reflected anywhere in AppleScript either, so
    // this is fully authoritative once set, same as lastKnownRepeatMode — there's
    // no external source to reconcile against on a fresh launch.
    private var lastKnownSpeed: Double = 1.0
    private static let speedCycle: [Double] = [1.0, 1.3, 1.5, 1.8, 2.0, 0.8]

    private var currentTrackURI: String = ""
    private var lastFavoriteCheckedURI: String = ""
    private var favoriteFetchTask: Task<Void, Never>?

    private var explicitCache: [String: Bool] = [:]
    private var explicitFetchTask: Task<Void, Never>?

    init() {
        setupPlaybackStateChangeObserver()
        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
    }

    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )

            for await _ in notifications {
                await self?.updatePlaybackInfo()
            }
        }
    }

    deinit {
        notificationTask?.cancel()
        artworkFetchTask?.cancel()
        favoriteFetchTask?.cancel()
        explicitFetchTask?.cancel()
    }

    // MARK: - Protocol Implementation
    func play() async { await executeCommand("play") }
    func pause() async { await executeCommand("pause") }
    func togglePlay() async { await executeCommand("playpause") }
    func nextTrack() async { await executeCommand("next track") }
    func previousTrack() async {
        await executeAndRefresh("previous track")
    }

    func seek(to time: Double) async {
        await executeAndRefresh("set player position to \(time)")
    }

    func toggleShuffle() async {
        await executeAndRefresh("set shuffling to not shuffling")
    }

    func toggleRepeat() async {
        guard let cliURL = spotifyCLIURL else {
            // Pre-spotify_cli Spotify: only off/all are reachable at all.
            await executeAndRefresh("set repeating to not repeating")
            return
        }

        // Matches the off -> all -> one -> off convention used elsewhere
        // (see NowPlayingController.toggleRepeat).
        let nextMode: RepeatMode
        let cliArgument: String
        switch playbackState.repeatMode {
        case .off:
            nextMode = .all
            cliArgument = "context"
        case .all:
            nextMode = .one
            cliArgument = "track"
        case .one:
            nextMode = .off
            cliArgument = "off"
        }

        lastKnownRepeatMode = nextMode
        playbackState.repeatMode = nextMode

        _ = await runSpotifyCLI(cliURL, ["repeat", cliArgument])
    }

    func setFavorite(_ favorite: Bool) async {
        guard let cliURL = spotifyCLIURL, !currentTrackURI.isEmpty else { return }

        playbackState.isFavorite = favorite
        // Prevents the updatePlaybackInfo() that follows this call (see
        // MusicManager.setFavorite) from immediately re-querying `library
        // contains` for the same track — that read is unreliable right after
        // our own write (verified: it kept reporting the pre-write state for
        // several seconds), so trust this optimistic value instead.
        lastFavoriteCheckedURI = currentTrackURI

        _ = await runSpotifyCLI(cliURL, ["library", favorite ? "add" : "remove", currentTrackURI])
    }

    func cycleSpeed() async {
        guard let cliURL = spotifyCLIURL else { return }

        let currentIndex = Self.speedCycle.firstIndex(of: lastKnownSpeed) ?? 0
        let nextSpeed = Self.speedCycle[(currentIndex + 1) % Self.speedCycle.count]

        lastKnownSpeed = nextSpeed
        playbackState.playbackRate = nextSpeed

        _ = await runSpotifyCLI(cliURL, ["speed", String(format: "%.1f", nextSpeed)])
    }

    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == playbackState.bundleIdentifier }
    }

    func updatePlaybackInfo() async {
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 11 else { return }

        let isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        let currentTrack = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        let currentTrackArtist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        let currentTrackAlbum = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        let currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        let duration = (descriptor.atIndex(6)?.doubleValue ?? 0)/1000
        let isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let isRepeating = descriptor.atIndex(8)?.booleanValue ?? false
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        let artworkURL = descriptor.atIndex(10)?.stringValue ?? ""
        let trackURI = descriptor.atIndex(11)?.stringValue ?? ""

        // AppleScript's "repeating" and spotify_cli's repeat state are two
        // different internal representations that have been confirmed live to
        // desync: setting repeat-one via spotify_cli leaves "repeating" reading
        // false indefinitely, not just briefly. Trusting it here would clobber
        // lastKnownRepeatMode back to .off on every refresh (e.g. every notch
        // reopen). So once spotify_cli is available, our own tracked state is
        // authoritative and the Boolean is ignored entirely; it's only used as
        // a best-effort fallback on older Spotify installs without spotify_cli,
        // where lastKnownRepeatMode is never set by anything.
        let resolvedRepeatMode: RepeatMode
        if spotifyCLIURL != nil {
            resolvedRepeatMode = lastKnownRepeatMode
        } else if !isRepeating {
            resolvedRepeatMode = .off
        } else {
            resolvedRepeatMode = lastKnownRepeatMode == .off ? .all : lastKnownRepeatMode
        }

        var state = PlaybackState(
            bundleIdentifier: "com.spotify.client",
            isPlaying: isPlaying,
            title: currentTrack,
            artist: currentTrackArtist,
            album: currentTrackAlbum,
            currentTime: currentTime,
            duration: duration,
            playbackRate: lastKnownSpeed,
            isShuffled: isShuffled,
            repeatMode: resolvedRepeatMode,
            lastUpdated: Date(),
            artwork: nil,
            volume: Double(volumePercentage) / 100.0,
            isFavorite: playbackState.isFavorite,
            isExplicit: playbackState.isExplicit,
            isPodcastContent: trackURI.hasPrefix("spotify:episode:")
        )

        if artworkURL == lastArtworkURL, let existingArtwork = self.playbackState.artwork {
            state.artwork = existingArtwork
        }

        currentTrackURI = trackURI

        if trackURI != lastFavoriteCheckedURI {
            lastFavoriteCheckedURI = trackURI
            state.isFavorite = false
            fetchFavoriteState(cliURL: spotifyCLIURL, uri: trackURI)
        }

        state.isExplicit = fetchExplicitState(uri: trackURI)

        playbackState = state

        if !artworkURL.isEmpty, let url = URL(string: artworkURL) {
            guard artworkURL != lastArtworkURL || state.artwork == nil else { return }
            artworkFetchTask?.cancel()

            let currentState = state

            artworkFetchTask = Task {
                do {
                    let data = try await ImageService.shared.fetchImageData(from: url)

                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        var updatedState = currentState
                        updatedState.artwork = data
                        self.playbackState = updatedState
                        self.lastArtworkURL = artworkURL
                        self.artworkFetchTask = nil
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.artworkFetchTask = nil
                    }
                }
            }
        }
    }

// MARK: - Private Methods

    private func executeCommand(_ command: String) async {
        let script = "tell application \"Spotify\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }

    private func executeAndRefresh(_ command: String) async {
        await executeCommand(command)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set currentVolume to sound volume
                set artworkURL to artwork url of current track
                set trackURI to id of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL, trackURI}
            on error
                return {false, "Not Playing", "Unknown", "Unknown", 0, 0, false, false, 50, "", ""}
            end try
        end tell
        """

        return try await AppleScriptHelper.execute(script)
    }

    // MARK: - spotify_cli

    private static func resolveSpotifyCLI() -> URL? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            return nil
        }
        let cliURL = appURL.appendingPathComponent("Contents/MacOS/spotify_cli")
        return FileManager.default.isExecutableFile(atPath: cliURL.path) ? cliURL : nil
    }

    @discardableResult
    private func runSpotifyCLI(_ cliURL: URL, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = cliURL
            process.arguments = arguments
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            process.terminationHandler = { _ in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Favorite state

    private func fetchFavoriteState(cliURL: URL?, uri: String) {
        guard let cliURL, !uri.isEmpty else { return }
        favoriteFetchTask?.cancel()
        favoriteFetchTask = Task { [weak self] in
            guard let self else { return }
            guard let output = await self.runSpotifyCLI(cliURL, ["library", "contains", uri, "--format", "json"]) else { return }
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contains = json["contains"] as? [String: Bool],
                  let isFavorite = contains[uri] else { return }

            await MainActor.run { [weak self] in
                guard let self, self.currentTrackURI == uri else { return }
                self.playbackState.isFavorite = isFavorite
            }
        }
    }

    // MARK: - Explicit tag

    // Spotify exposes no explicit flag over AppleScript or spotify_cli, so this
    // reads it from the same public, unauthenticated catalog endpoint the embed
    // player uses — no OAuth, no focus requirement. Cached per track ID since
    // it's immutable catalog metadata, not playback state.
    private func fetchExplicitState(uri: String) -> Bool {
        guard !uri.isEmpty else { return false }
        if let cached = explicitCache[uri] { return cached }

        guard let trackID = uri.split(separator: ":").last.map(String.init),
              let url = URL(string: "https://open.spotify.com/embed/track/\(trackID)") else {
            return false
        }

        explicitFetchTask?.cancel()
        explicitFetchTask = Task { [weak self] in
            guard let self else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let html = String(data: data, encoding: .utf8) else { return }

            let isExplicit = html.contains("\"isExplicit\":true")
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.explicitCache[uri] = isExplicit
                guard self.currentTrackURI == uri else { return }
                self.playbackState.isExplicit = isExplicit
            }
        }

        return false
    }

}
