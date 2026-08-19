//
//  NowPlayingController.swift
//  Knotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
        await fetchShuffleStateIfSupported()
        await fetchRepeatStateIfSupported()
    }

    // MARK: - Properties
    // Empty bundleIdentifier is the "nothing playing yet" sentinel used
    // throughout this controller (see handleAdapterUpdate) — defaulting to
    // Apple Music here made MusicManager believe Apple Music was already the
    // active source before any real MediaRemote data arrived.
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: ""
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    var supportsSpeedControl: Bool { true }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetPlaybackSpeedFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?
    private var appleMusicShuffleObserverTask: Task<Void, Never>?
    private var spotifyShuffleObserverTask: Task<Void, Never>?

    // MARK: - Initialization
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString),
            let MRMediaRemoteSetPlaybackSpeedPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetPlaybackSpeed" as CFString)

        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetPlaybackSpeedFunction = unsafeBitCast(
            MRMediaRemoteSetPlaybackSpeedPointer, to: (@convention(c) (Int) -> Void).self)

        Task { await setupNowPlayingObserver() }
        setupShuffleSyncObservers()
    }

    deinit {
        streamTask?.cancel()
        appleMusicShuffleObserverTask?.cancel()
        spotifyShuffleObserverTask?.cancel()

        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close()
            }
        }
        
        if let process = self.process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }
    
    func toggleShuffle() async {
        // MediaRemote's shuffle command/state isn't reliably honored or reported
        // by third-party apps (notably Spotify never reports it, and Apple Music
        // only sometimes does). For apps we know have an AppleScript dictionary,
        // toggle the real property directly and re-read it, matching
        // AppleMusicController/SpotifyController.
        switch playbackState.bundleIdentifier {
        case "com.apple.Music":
            try? await AppleScriptHelper.executeVoid(
                "tell application \"Music\" to set shuffle enabled to not shuffle enabled")
            try? await Task.sleep(for: .milliseconds(150))
            await fetchShuffleStateIfSupported()
        case "com.spotify.client":
            try? await AppleScriptHelper.executeVoid(
                "tell application \"Spotify\" to set shuffling to not shuffling")
            try? await Task.sleep(for: .milliseconds(150))
            await fetchShuffleStateIfSupported()
        default:
            // MRMediaRemoteSendCommandFunction(6, nil)
            MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
            playbackState.isShuffled.toggle()
        }
    }
    
    func toggleRepeat() async {
        // MediaRemote's repeat command/state has the same reliability problem as shuffle
        // for Apple Music and Spotify — confirmed by testing directly against a running
        // Spotify, where MRMediaRemoteSetRepeatMode is silently ignored entirely — so
        // toggle the real property directly via AppleScript and re-read it for those
        // two apps. Spotify's AppleScript dictionary only exposes a boolean "repeating",
        // no repeat-one — this path only runs when Spotify is being driven through the
        // generic Now Playing controller rather than SpotifyController, which reaches
        // repeat-one via spotify_cli instead.
        switch playbackState.bundleIdentifier {
        case "com.apple.Music":
            try? await AppleScriptHelper.executeVoid("""
                tell application "Music"
                    if song repeat is off then
                        set song repeat to all
                    else if song repeat is all then
                        set song repeat to one
                    else
                        set song repeat to off
                    end if
                end tell
                """)
            try? await Task.sleep(for: .milliseconds(150))
            await fetchRepeatStateIfSupported()
        case "com.spotify.client":
            try? await AppleScriptHelper.executeVoid(
                "tell application \"Spotify\" to set repeating to not repeating")
            try? await Task.sleep(for: .milliseconds(150))
            await fetchRepeatStateIfSupported()
        default:
            // MRMediaRemoteSendCommandFunction(7, nil)
            let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
            playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
            MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
        }
    }
    
    // Confirmed live against Apple Podcasts: MRMediaRemoteSetPlaybackSpeed is
    // not an absolute setter — 1 steps to the next preset, 2 to the previous,
    // through a fixed ladder (0.8, 1.0, 1.3, 1.5, 1.8, 2.0), clamping rather
    // than wrapping at either end. To reproduce the 1x -> 1.3x -> 1.5x -> 1.8x
    // -> 2x -> 0.8x -> 1x cycle used elsewhere, every step here is a single
    // forward call except unwinding from the ceiling back to the floor, which
    // needs repeated backward calls since a forward call there just clamps.
    private static let speedCycle: [Double] = [1.0, 1.3, 1.5, 1.8, 2.0, 0.8]

    func cycleSpeed() async {
        let current = playbackState.playbackRate
        let currentIndex = Self.speedCycle.indices.min(by: {
            abs(Self.speedCycle[$0] - current) < abs(Self.speedCycle[$1] - current)
        }) ?? 0

        if currentIndex == Self.speedCycle.count - 2 {
            for _ in 0..<(Self.speedCycle.count - 1) {
                MRMediaRemoteSetPlaybackSpeedFunction(2)
                try? await Task.sleep(for: .milliseconds(80))
            }
        } else {
            MRMediaRemoteSetPlaybackSpeedFunction(1)
        }
    }

    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == "com.spotify.client" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }
        
        playbackState.volume = clampedLevel
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream"]
        
        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self] in
                await self?.processJSONStream()
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    /// Apple Music and Spotify each broadcast a distributed notification whenever
    /// their player state (including shuffle and repeat) changes. MediaRemote's own
    /// shuffle/repeat fields don't reliably reflect these apps, so listen directly and
    /// re-read the real properties via AppleScript, same as the dedicated controllers do.
    private func setupShuffleSyncObservers() {
        appleMusicShuffleObserverTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.apple.Music.playerInfo")
            )
            for await _ in notifications {
                await self?.fetchShuffleStateIfSupported()
                await self?.fetchRepeatStateIfSupported()
            }
        }

        spotifyShuffleObserverTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            for await _ in notifications {
                await self?.fetchShuffleStateIfSupported()
                await self?.fetchRepeatStateIfSupported()
            }
        }
    }

    // MARK: - Async Stream Processing
    private func processJSONStream() async {
        guard let pipeHandler = self.pipeHandler else { return }
        
        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }
    }

    // MARK: - Update Methods
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false
        let resolvedBundleIdentifier = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier
            ?? (diff ? self.playbackState.bundleIdentifier : "")

        var newPlaybackState = PlaybackState(bundleIdentifier: playbackState.bundleIdentifier)
        
        newPlaybackState.title = payload.title ?? (diff ? self.playbackState.title : "")
        newPlaybackState.artist = payload.artist ?? (diff ? self.playbackState.artist : "")
        newPlaybackState.album = payload.album ?? (diff ? self.playbackState.album : "")
        newPlaybackState.duration = payload.duration ?? (diff ? self.playbackState.duration : 0)

        // Only Apple Music's uniqueIdentifier is a real public catalog track ID —
        // the same field from another app's now-playing info means something else.
        newPlaybackState.appleMusicTrackID = resolvedBundleIdentifier == "com.apple.Music"
            ? payload.uniqueIdentifier ?? (diff ? self.playbackState.appleMusicTrackID : nil)
            : nil
        
        if let elapsedTime = payload.elapsedTime {
            newPlaybackState.currentTime = elapsedTime
        } else if diff {
            if payload.playing == false {
                let timeSinceLastUpdate = Date().timeIntervalSince(self.playbackState.lastUpdated)
                newPlaybackState.currentTime = self.playbackState.currentTime + (self.playbackState.playbackRate * timeSinceLastUpdate)
            } else {
                newPlaybackState.currentTime = self.playbackState.currentTime
            }
        } else {
            newPlaybackState.currentTime = 0
        }

        
        if resolvedBundleIdentifier == "com.apple.Music" || resolvedBundleIdentifier == "com.spotify.client" {
            // MediaRemote's shuffleMode field for these two apps is unreliable — absent,
            // stale, or briefly wrong right after a track change (e.g. on skip). Trust
            // only the AppleScript-derived value from fetchShuffleStateIfSupported(),
            // which is kept in sync via the playerInfo/PlaybackStateChanged observers,
            // toggleShuffle(), and the bundle-switch check below.
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        } else if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !diff {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        }
        if resolvedBundleIdentifier == "com.apple.Music" || resolvedBundleIdentifier == "com.spotify.client" {
            // Same unreliability as shuffle for these two apps — trust only the
            // AppleScript-derived value, kept in sync via the observers/toggle/bundle-switch below.
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        } else if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newPlaybackState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if !diff {
            newPlaybackState.artwork = nil
        }

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            newPlaybackState.lastUpdated = date
        } else if !diff {
            newPlaybackState.lastUpdated = Date()
        } else {
            newPlaybackState.lastUpdated = self.playbackState.lastUpdated
        }

        newPlaybackState.playbackRate = payload.playbackRate ?? (diff ? self.playbackState.playbackRate : 1.0)
        newPlaybackState.isPlaying = payload.playing ?? (diff ? self.playbackState.isPlaying : false)
        newPlaybackState.bundleIdentifier = resolvedBundleIdentifier
        // Only confirmed source of podcast content on this generic path —
        // see the matching field on PlaybackState.
        newPlaybackState.isPodcastContent = resolvedBundleIdentifier == "com.apple.podcasts"

        newPlaybackState.volume = payload.volume ?? (diff ? self.playbackState.volume : 0.5)

        let previousBundleIdentifier = self.playbackState.bundleIdentifier
        self.playbackState = newPlaybackState

        // Fetch favorite state for supported apps asynchronously
        // await fetchFavoriteStateIfSupported()

        // MediaRemote's shuffleMode/repeatMode fields are absent or stale for Apple
        // Music/Spotify most of the time, so re-read the real values whenever the
        // source app changes.
        if newPlaybackState.bundleIdentifier != previousBundleIdentifier {
            await fetchShuffleStateIfSupported()
            await fetchRepeatStateIfSupported()
        }
    }
    
     // Sending AppleEvents to Music/Spotify for the first time triggers the
     // system "wants to control" automation prompt — skip it during onboarding
     // so it doesn't fire unprompted over the welcome screen before the user
     // has agreed to anything. MusicManager resyncs once onboarding finishes.
     private func onboardingInProgress() async -> Bool {
         await MainActor.run { KnotchViewCoordinator.shared.firstLaunch }
     }

     private func fetchFavoriteStateIfSupported() async {
         guard await !onboardingInProgress() else { return }
         let bundleID = playbackState.bundleIdentifier

         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }
             
             let script = """
             tell application "Music"
                 try
                     return favorited of current track
                 on error
                     return false
                 end try
             end tell
             """
             if let result = try? await AppleScriptHelper.execute(script) {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }

     private func fetchShuffleStateIfSupported() async {
         guard await !onboardingInProgress() else { return }
         let bundleID = playbackState.bundleIdentifier
         let script: String

         switch bundleID {
         case "com.apple.Music":
             guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return }
             script = """
             tell application "Music"
                 try
                     return shuffle enabled
                 on error
                     return false
                 end try
             end tell
             """
         case "com.spotify.client":
             guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return }
             script = """
             tell application "Spotify"
                 try
                     return shuffling
                 on error
                     return false
                 end try
             end tell
             """
         default:
             return
         }

         if let result = try? await AppleScriptHelper.execute(script) {
             var updated = self.playbackState
             updated.isShuffled = result.booleanValue
             self.playbackState = updated
         }
     }

     private func fetchRepeatStateIfSupported() async {
         guard await !onboardingInProgress() else { return }
         let bundleID = playbackState.bundleIdentifier
         let script: String

         switch bundleID {
         case "com.apple.Music":
             guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return }
             script = """
             tell application "Music"
                 try
                     set repeatState to song repeat
                     if repeatState is off then
                         return 1
                     else if repeatState is one then
                         return 2
                     else
                         return 3
                     end if
                 on error
                     return 1
                 end try
             end tell
             """
         case "com.spotify.client":
             // Spotify only exposes a boolean "repeating" — no repeat-one — so map
             // it onto the same off/all values used elsewhere for this app.
             guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return }
             script = """
             tell application "Spotify"
                 try
                     if repeating then
                         return 3
                     else
                         return 1
                     end if
                 on error
                     return 1
                 end try
             end tell
             """
         default:
             return
         }

         if let result = try? await AppleScriptHelper.execute(script) {
             var updated = self.playbackState
             updated.repeatMode = RepeatMode(rawValue: Int(result.int32Value)) ?? .off
             self.playbackState = updated
         }
     }

}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
    let uniqueIdentifier: Int?
}

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    private var buffer = ""
    
    init() {
        self.pipe = Pipe()
        self.fileHandle = pipe.fileHandleForReading
    }
    
    func getPipe() -> Pipe {
        return pipe
    }
    
    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            try await self.processLines(as: type) { decodedObject in
                await onLine(decodedObject)
            }
        } catch {
            print("Error processing JSON stream: \(error)")
        }
    }
    
    private func processLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async throws {
        while true {
            let data = try await readData()
            guard !data.isEmpty else { break }
            
            if let chunk = String(data: data, encoding: .utf8) {
                buffer.append(chunk)
                
                while let range = buffer.range(of: "\n") {
                    let line = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    
                    if !line.isEmpty {
                        await processJSONLine(line, as: type, onLine: onLine)
                    }
                }
            }
        }
    }
    
    private func processJSONLine<T: Decodable>(_ line: String, as type: T.Type, onLine: @escaping (T) async -> Void) async {
        guard let data = line.data(using: .utf8) else {
            return
        }
        do {
            let decodedObject = try JSONDecoder().decode(T.self, from: data)
            await onLine(decodedObject)
        } catch {
            // Ignore lines that can't be decoded
        }
    }
    
    private func readData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }
    
    func close() async {
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("Error closing pipe handler: \(error)")
        }
    }
}
