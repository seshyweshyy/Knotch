//
//  AppleMusicAudioQualityResolver.swift
//  Knotch
//
//  Resolves whether the current Apple Music track is available in Lossless
//  or Dolby Atmos via MusicKit's public catalog API — the same audioVariants
//  metadata Apple Music's own UI badges are driven by, i.e. what the track
//  supports rather than a live read of the current audio signal path (macOS
//  exposes no API for the latter). Requires the MusicKit capability to be
//  enabled for this app's ID in the Apple Developer portal to actually
//  authorize; until then, lookups just resolve to "unavailable".
//

import Foundation
import MusicKit

actor AppleMusicAudioQualityResolver {
    static let shared = AppleMusicAudioQualityResolver()

    struct Quality: Equatable {
        var isLossless: Bool
        var isDolbyAtmos: Bool

        static let unavailable = Quality(isLossless: false, isDolbyAtmos: false)
    }

    private var cache: [Int: Quality] = [:]
    private var inFlight: [Int: Task<Quality, Never>] = [:]

    func quality(forTrackID trackID: Int) async -> Quality {
        if let cached = cache[trackID] { return cached }
        if let existing = inFlight[trackID] { return await existing.value }

        let task = Task<Quality, Never> { await self.resolve(trackID: trackID) }
        inFlight[trackID] = task
        let result = await task.value
        cache[trackID] = result
        inFlight[trackID] = nil
        return result
    }

    private func resolve(trackID: Int) async -> Quality {
        guard await ensureAuthorized() else { return .unavailable }

        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID("\(trackID)"))
        request.properties = [.audioVariants]

        guard let song = try? await request.response().items.first,
              let variants = song.audioVariants else {
            return .unavailable
        }

        return Quality(
            isLossless: variants.contains(.lossless) || variants.contains(.highResolutionLossless),
            isDolbyAtmos: variants.contains(.dolbyAtmos)
        )
    }

    private func ensureAuthorized() async -> Bool {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await MusicAuthorization.request() == .authorized
        default:
            return false
        }
    }
}
