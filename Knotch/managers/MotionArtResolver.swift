//
//  MotionArtResolver.swift
//  Knotch
//
//  Resolves Apple Music's public "motion artwork" video for the current
//  track, when one exists. Uses only public, unauthenticated endpoints:
//  the iTunes lookup/search API for catalog matching, and Apple Music's
//  own public album page HTML — which embeds an <amp-ambient-video> tag
//  for albums that have motion artwork — for the actual video URL. No
//  developer token, no login, no private API involved.
//
//  Callers are expected to check the relevant Defaults toggle themselves
//  before calling in — this service doesn't know about settings.
//

import Foundation

actor MotionArtResolver {
    static let shared = MotionArtResolver()

    private struct CacheKey: Hashable {
        let trackID: Int?
        let title: String
        let artist: String
        let album: String
    }

    // A stored `nil` means "already looked up, confirmed no motion art" —
    // distinct from "not looked up yet" (no entry at all).
    private var cache: [CacheKey: URL?] = [:]
    private var inFlight: [CacheKey: Task<URL?, Never>] = [:]

    func motionArtURL(trackID: Int?, title: String, artist: String, album: String) async -> URL? {
        guard !artist.isEmpty, !album.isEmpty else { return nil }
        let key = CacheKey(trackID: trackID, title: title, artist: artist, album: album)

        if let cached = cache[key] {
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<URL?, Never> {
            await self.resolve(trackID: trackID, title: title, artist: artist, album: album)
        }
        inFlight[key] = task
        let result = await task.value
        cache[key] = result
        inFlight[key] = nil
        return result
    }

    // MARK: - Resolution pipeline

    private func resolve(trackID: Int?, title: String, artist: String, album: String) async -> URL? {
        guard let collectionID = await resolveCollectionID(trackID: trackID, artist: artist, album: album) else {
            return nil
        }
        return await fetchMotionArtURL(collectionID: collectionID)
    }

    private func resolveCollectionID(trackID: Int?, artist: String, album: String) async -> Int? {
        if let trackID, let collectionID = await lookupCollectionID(trackID: trackID) {
            return collectionID
        }
        return await searchCollectionID(artist: artist, album: album)
    }

    // Direct path: a real Apple Music track ID (MediaRemote's uniqueIdentifier)
    // resolved to its exact collection — no fuzzy matching involved.
    private func lookupCollectionID(trackID: Int) async -> Int? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(trackID)") else { return nil }
        guard let data = try? await fetch(url) else { return nil }
        return Self.parseCatalogResponse(data).first?.collectionId
    }

    // Fallback path for anything without a trustworthy Apple Music track ID
    // (e.g. Spotify) — fuzzy-matched by artist + album, same as the search
    // step in known reference implementations (e.g. m8tec's ContainsAlbumName).
    private func searchCollectionID(artist: String, album: String) async -> Int? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url else { return nil }
        guard let data = try? await fetch(url) else { return nil }

        let normalizedArtist = Self.normalize(artist)
        let normalizedAlbum = Self.normalize(album)

        for result in Self.parseCatalogResponse(data) {
            guard let collectionId = result.collectionId else { continue }
            let candidateArtist = Self.normalize(result.artistName ?? "")
            let candidateAlbum = Self.normalize(result.collectionName ?? "")
            guard !candidateArtist.isEmpty, !candidateAlbum.isEmpty else { continue }

            let artistMatches = candidateArtist.contains(normalizedArtist) || normalizedArtist.contains(candidateArtist)
            let albumMatches = candidateAlbum.contains(normalizedAlbum) || normalizedAlbum.contains(candidateAlbum)
            if artistMatches && albumMatches {
                return collectionId
            }
        }
        return nil
    }

    // MARK: - Album page scrape

    private func fetchMotionArtURL(collectionID: Int) async -> URL? {
        guard let pageURL = URL(string: "https://music.apple.com/us/album/\(collectionID)") else { return nil }
        guard let data = try? await fetch(pageURL), let html = String(data: data, encoding: .utf8) else { return nil }
        return Self.extractAmbientVideoURL(from: html)
    }

    private static func extractAmbientVideoURL(from html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"<amp-ambient-video[^>]*\bsrc="([^"]+)""#) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let srcRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return URL(string: String(html[srcRange]))
    }

    // MARK: - Networking

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - iTunes JSON

    private struct ITunesCatalogResponse: Decodable {
        let results: [ITunesCatalogResult]
    }

    private struct ITunesCatalogResult: Decodable {
        let collectionId: Int?
        let artistName: String?
        let collectionName: String?
    }

    private static func parseCatalogResponse(_ data: Data) -> [ITunesCatalogResult] {
        (try? JSONDecoder().decode(ITunesCatalogResponse.self, from: data))?.results ?? []
    }

    private static func normalize(_ input: String) -> String {
        let lowered = input.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            out.append(CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " ")
        }
        return out
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
