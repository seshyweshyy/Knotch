//
//  SpotifyArtistLookup.swift
//  Knotch
//

import AppKit
import Foundation

// AppleScript's "artist of current track" and MediaRemote's artist field both
// only carry Spotify's primary artist. The full credit list lives in the
// catalog, reachable through spotify_cli (or, on older builds, the embed page).
enum SpotifyArtistLookup {
    /// Full artist list for a track URI, or [] if it couldn't be resolved.
    static func artists(forTrackURI uri: String) async -> [String] {
        if let cliURL = resolveCLI() {
            return await artistsViaCLI(cliURL, uri: uri)
        }
        return await artistsViaEmbed(uri: uri)
    }

    /// Full artist list for whatever Spotify is playing right now, resolved via
    /// spotify_cli's now-playing URI. Used where no track URI is available
    /// (MediaRemote's identifier for Spotify isn't a Spotify URI). `title` guards
    /// against a stale URI from a track that has already changed.
    static func artistsForCurrentTrack(matchingTitle title: String) async -> [String] {
        guard let cliURL = resolveCLI(),
              let output = await run(cliURL, ["now-playing", "--format", "json"]),
              let json = jsonObject(output),
              let current = json["currently_playing"] as? [String: Any],
              let uri = current["uri"] as? String,
              uri.hasPrefix("spotify:track:") else { return [] }
        return await artistsViaCLI(cliURL, uri: uri, expectedTitle: title)
    }

    /// Current track followed by the upcoming queue, each with its full artist
    /// string, from a single `spotify_cli queue` call. Callers cache these so
    /// queued tracks already have their full artists when they start playing.
    /// Callers with a track URI key on it; those without key on the title.
    static func queueArtists() async -> [(uri: String, title: String, artists: String)] {
        guard let cliURL = resolveCLI(),
              let output = await run(cliURL, ["queue", "--format", "json"]),
              let json = jsonObject(output) else { return [] }

        var entries: [[String: Any]] = []
        if let current = json["currently_playing"] as? [String: Any] { entries.append(current) }
        entries += json["next_tracks"] as? [[String: Any]] ?? []

        return entries.compactMap { entry in
            guard let uri = entry["uri"] as? String, uri.hasPrefix("spotify:track:"),
                  let name = entry["name"] as? String,
                  let artist = entry["artist"] as? String, !artist.isEmpty else { return nil }
            return (uri, name, artist)
        }
    }

    // MARK: - spotify_cli

    private static func resolveCLI() -> URL? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            return nil
        }
        let cliURL = appURL.appendingPathComponent("Contents/MacOS/spotify_cli")
        return FileManager.default.isExecutableFile(atPath: cliURL.path) ? cliURL : nil
    }

    private static func artistsViaCLI(_ cliURL: URL, uri: String, expectedTitle: String? = nil) async -> [String] {
        guard let output = await run(cliURL, ["lookup", uri, "--format", "json"]),
              let json = jsonObject(output),
              let entity = (json["entities"] as? [[String: Any]])?.first,
              let contributors = entity["contributors"] as? [[String: Any]] else { return [] }
        if let expectedTitle, let name = entity["name"] as? String, name != expectedTitle { return [] }
        return contributors.compactMap { $0["name"] as? String }
    }

    private static func run(_ cliURL: URL, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = cliURL
            process.arguments = arguments
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            process.terminationHandler = { _ in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Embed fallback

    // The embed page ships the track's full artist list in its __NEXT_DATA__ JSON.
    private static func artistsViaEmbed(uri: String) async -> [String] {
        guard let trackID = uri.split(separator: ":").last.map(String.init),
              let url = URL(string: "https://open.spotify.com/embed/track/\(trackID)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8),
              let start = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let json = jsonObject(String(html[start.upperBound..<end.lowerBound])),
              let props = json["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let stateData = state["data"] as? [String: Any],
              let entity = stateData["entity"] as? [String: Any],
              let artists = entity["artists"] as? [[String: Any]] else { return [] }
        return artists.compactMap { $0["name"] as? String }
    }
}
