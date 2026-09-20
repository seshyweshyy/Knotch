//
//  LockScreenLyrics.swift
//  Knotch
//
//  Time-synced lyrics shown beside the expanded album art on the lock screen.
//  Fetches LRC lyrics from LRCLIB (exact lookup first, then a scored search),
//  and renders them as a centred, auto-scrolling column where the current
//  line is sharp and the surrounding lines fade and blur with distance.
//
//  LRCLIBLyricsProvider is shared with the notch's single-line lyrics
//  (MusicManager.fetchLyricsIfAvailable), so both find the same tracks.
//

import SwiftUI

// MARK: - Model

struct SyncedLyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: TimeInterval?
    let text: String
}

struct SyncedLyrics: Equatable, Sendable {
    let lines: [SyncedLyricLine]
    let isSynced: Bool

    /// Index of the line being sung at `position`, or nil during the intro
    /// (before the first timestamp) and for unsynced lyrics.
    func activeIndex(at position: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if let time = lines[mid].time, time <= position {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

// MARK: - LRCLIB provider

actor LRCLIBLyricsProvider {
    static let shared = LRCLIBLyricsProvider()

    struct Query: Hashable, Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: Int
    }

    private struct Response: Decodable {
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// `nil` payload = confirmed missing (cached so a track without lyrics
    /// isn't re-searched every time the art is expanded). Network errors are
    /// never cached.
    private var cache: [Query: SyncedLyrics?] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    func lyrics(for query: Query) async throws -> SyncedLyrics? {
        if let cached = cache[query] { return cached }

        let cleanTitle = Self.cleanedTitle(query.title)
        let primaryArtist = Self.primaryArtist(query.artist)

        // A plain-text hit is only a fallback: LRCLIB's exact lookup often
        // lands on a plain-only record even when a synced one exists for the
        // same song, so keep searching until a synced match turns up.
        var synced: SyncedLyrics?
        var plain: SyncedLyrics?

        if let exact = try await exactMatch(for: query), let lyrics = Self.makeLyrics(from: exact) {
            if lyrics.isSynced { synced = lyrics } else { plain = lyrics }
        }

        if synced == nil {
            let attempts: [[URLQueryItem]] = [
                [URLQueryItem(name: "track_name", value: cleanTitle),
                 URLQueryItem(name: "artist_name", value: primaryArtist)],
                [URLQueryItem(name: "q", value: "\(cleanTitle) \(primaryArtist)")]
            ]
            for items in attempts {
                let responses = try await search(items)
                guard let best = Self.bestResponse(in: responses, for: query),
                      let lyrics = Self.makeLyrics(from: best) else { continue }
                if lyrics.isSynced {
                    synced = lyrics
                    break
                }
                plain = plain ?? lyrics
            }
        }

        let result = synced ?? plain
        cache[query] = .some(result)
        return result
    }

    // MARK: Requests

    private func exactMatch(for query: Query) async throws -> Response? {
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist)
        ]
        if !query.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: query.album)) }
        if query.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(query.duration))) }

        guard let data = try await fetch("get", items, allowsNotFound: true) else { return nil }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func search(_ items: [URLQueryItem]) async throws -> [Response] {
        guard let data = try await fetch("search", items, allowsNotFound: false) else { return [] }
        return try JSONDecoder().decode([Response].self, from: data)
    }

    private func fetch(_ endpoint: String, _ items: [URLQueryItem], allowsNotFound: Bool) async throws -> Data? {
        var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)")
        components?.queryItems = items
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("Knotch (https://github.com/seshyweshyy/Knotch)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200..<300: return data
        case 404 where allowsNotFound: return nil
        default: throw URLError(.badServerResponse)
        }
    }

    // MARK: Matching

    private static func bestResponse(in responses: [Response], for query: Query) -> Response? {
        var best: (response: Response, score: Int)?
        for response in responses {
            guard response.instrumental != true,
                  hasText(response.syncedLyrics) || hasText(response.plainLyrics),
                  let score = matchScore(response, query: query)
            else { continue }
            if best == nil || score > best!.score { best = (response, score) }
        }
        return best?.response
    }

    /// nil = not the same song. Title and artist must both plausibly match;
    /// the rest only ranks candidates (synced beats plain outright, close durations
    /// beat far ones so a live/extended cut doesn't win over the studio take).
    private static func matchScore(_ response: Response, query: Query) -> Int? {
        let title = normalized(cleanedTitle(query.title))
        let artist = normalized(primaryArtist(query.artist))
        let album = normalized(query.album)
        let responseTitle = normalized(cleanedTitle(response.trackName ?? ""))
        let responseArtist = normalized(response.artistName ?? "")
        let responseAlbum = normalized(response.albumName ?? "")

        var score = 0
        if responseTitle == title { score += 120 }
        else if !title.isEmpty, responseTitle.contains(title) || title.contains(responseTitle), !responseTitle.isEmpty { score += 60 }
        else { return nil }

        if responseArtist == artist { score += 90 }
        else if !artist.isEmpty, responseArtist.contains(artist) || artist.contains(responseArtist), !responseArtist.isEmpty { score += 45 }
        else { return nil }

        if !album.isEmpty, responseAlbum == album { score += 35 }
        if hasText(response.syncedLyrics) { score += 60 }
        if let duration = response.duration, query.duration > 0 {
            let delta = abs(Int(duration.rounded()) - query.duration)
            if delta <= 2 { score += 24 } else if delta <= 6 { score += 12 } else if delta > 20 { score -= 40 }
        }
        return score
    }

    private static func hasText(_ string: String?) -> Bool {
        string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func normalized(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops the "(From "Film")", "[Remastered]", "- Live" style suffixes that
    /// streaming services add and LRCLIB titles don't carry.
    private static func cleanedTitle(_ title: String) -> String {
        var cleaned = title
        cleaned = cleaned.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let dash = cleaned.range(of: " - ") { cleaned = String(cleaned[..<dash.lowerBound]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    /// MusicManager can hand us "A, B & C" (full Spotify artist list); LRCLIB
    /// indexes the lead artist.
    private static func primaryArtist(_ artist: String) -> String {
        let separators = [", ", " & ", " feat. ", " feat ", " ft. ", " x ", " × "]
        var primary = artist
        for separator in separators {
            if let range = primary.range(of: separator, options: .caseInsensitive) {
                primary = String(primary[..<range.lowerBound])
            }
        }
        primary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary.isEmpty ? artist : primary
    }

    // MARK: Parsing

    private static func makeLyrics(from response: Response) -> SyncedLyrics? {
        if response.instrumental == true { return nil }

        let synced = parseLRC(response.syncedLyrics)
        if !synced.isEmpty { return SyncedLyrics(lines: synced, isSynced: true) }

        let plain = (response.plainLyrics ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { SyncedLyricLine(id: $0.offset, time: nil, text: $0.element) }
        return plain.isEmpty ? nil : SyncedLyrics(lines: plain, isSynced: false)
    }

    /// Handles multiple timestamps per line (`[00:10.00][01:20.00]chorus`),
    /// 1–3 digit fractions, and strips enhanced-LRC word tags (`<00:10.50>`).
    private static func parseLRC(_ lrc: String?) -> [SyncedLyricLine] {
        guard let lrc, let stamp = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#),
              let wordTag = try? NSRegularExpression(pattern: #"<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>"#)
        else { return [] }

        var parsed: [(time: TimeInterval, text: String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: line.length))
            guard let last = matches.last else { continue }

            var text = line.substring(from: last.range.location + last.range.length)
            text = wordTag.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minutes = Double(line.substring(with: match.range(at: 1))),
                      let seconds = Double(line.substring(with: match.range(at: 2)))
                else { continue }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = line.substring(with: match.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                parsed.append((minutes * 60 + seconds + fraction, text))
            }
        }

        return parsed
            .sorted { $0.time < $1.time }
            .enumerated()
            .map { SyncedLyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}

// MARK: - Store

/// Loads lyrics for whatever `sync(query:)` was last handed. Passing nil
/// (collapsed / feature off / nothing playing) cancels any in-flight lookup
/// and resets, so the next expand retries after a network failure.
@MainActor
final class LockScreenLyricsStore: ObservableObject {
    static let shared = LockScreenLyricsStore()

    enum State: Equatable {
        case idle
        case loading
        case loaded(SyncedLyrics)
        case unavailable
    }

    @Published private(set) var state: State = .idle

    /// Whether the lyrics column should take up space beside the art. False
    /// once a lookup comes back empty so the art recentres instead of sitting
    /// off to one side next to nothing.
    var showsColumn: Bool {
        switch state {
        case .loading, .loaded: return true
        case .idle, .unavailable: return false
        }
    }

    private var currentQuery: LRCLIBLyricsProvider.Query?
    private var task: Task<Void, Never>?

    func sync(query: LRCLIBLyricsProvider.Query?) {
        guard query != currentQuery else { return }
        task?.cancel()
        currentQuery = query

        guard let query else {
            state = .idle
            return
        }

        state = .loading
        task = Task { [weak self] in
            let result: State
            do {
                let lyrics = try await LRCLIBLyricsProvider.shared.lyrics(for: query)
                result = lyrics.map(State.loaded) ?? .unavailable
            } catch {
                result = .unavailable
            }
            guard !Task.isCancelled, let self, self.currentQuery == query else { return }
            self.state = result
        }
    }
}

// MARK: - Click hit-testing

/// The lock-screen window swallows the first SwiftUI tap on the lyrics (the
/// same reason the album art thumbnail is hit-tested by a window-level event
/// monitor), so line taps are resolved the same way: rows report their frames
/// here and LiquidGlassWidgetWindowController's mouse-down monitor asks
/// `handleClick` before AppKit dispatches the event.
final class LyricsHitRegions {
    static let shared = LyricsHitRegions()

    /// All frames are in the widget root's top-left-origin "widgetRootSpace".
    var columnFrame: CGRect = .zero
    var lineFrames: [Int: CGRect] = [:]
    var onLineTap: ((Int) -> Void)?

    func reset() {
        columnFrame = .zero
        lineFrames = [:]
        onLineTap = nil
    }

    /// Returns true if the click landed on a line and was handled.
    func handleClick(at point: CGPoint) -> Bool {
        guard columnFrame != .zero, columnFrame.contains(point), let onLineTap else { return false }
        guard let hit = lineFrames.first(where: { $0.value.minY <= point.y && point.y <= $0.value.maxY }) else { return false }
        onLineTap(hit.key)
        return true
    }
}

private struct LineFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - View

struct LockScreenLyricsView: View {
    @ObservedObject var store: LockScreenLyricsStore
    @ObservedObject private var musicManager = MusicManager.shared

    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat
    /// Full-bleed motion art behind the text: adds a feathered dark scrim and
    /// a tighter shadow so lines stay readable over busy footage.
    var overArtwork = false

    /// Lines switch slightly before their timestamp so the highlight lands as
    /// the words start rather than a beat after.
    private let leadTime: TimeInterval = 0.2

    /// Where a click just sent playback. The real position only catches up
    /// once the player confirms the seek (an AppleScript round trip for
    /// Music/Spotify), so without this the highlight snaps back to the old
    /// line for a moment and the click looks like it did nothing.
    @State private var pendingSeek: (position: TimeInterval, date: Date)?
    private let pendingSeekWindow: TimeInterval = 1.5

    private func playbackPosition(at date: Date) -> TimeInterval {
        if let pendingSeek, date.timeIntervalSince(pendingSeek.date) < pendingSeekWindow {
            let rate = musicManager.isPlaying ? musicManager.playbackRate : 0
            return pendingSeek.position + max(0, date.timeIntervalSince(pendingSeek.date)) * rate
        }
        return musicManager.estimatedPlaybackPosition(at: date)
    }

    private func seek(to time: TimeInterval) {
        pendingSeek = (time, Date())
        musicManager.seek(to: time)
    }

    var body: some View {
        content
            .frame(width: width, height: height)
            .background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named("widgetRootSpace"))
                    Color.clear
                        .onChange(of: frame, initial: true) { _, newFrame in
                            LyricsHitRegions.shared.columnFrame = newFrame
                        }
                }
            )
            .onDisappear { LyricsHitRegions.shared.reset() }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.14),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .shadow(color: .black.opacity(overArtwork ? 0.55 : 0.3), radius: overArtwork ? 4 : 8, x: 0, y: 1)
            .shadow(color: .black.opacity(overArtwork ? 0.35 : 0), radius: 16, x: 0, y: 2)
            .background {
                // Blurred so it reads as a soft darkening around the text
                // rather than a panel; only as tall/wide as the column so the
                // rest of the artwork stays untouched.
                if overArtwork {
                    RoundedRectangle(cornerRadius: 60, style: .continuous)
                        .fill(.black.opacity(0.42))
                        .blur(radius: 45)
                        .padding(.horizontal, -10)
                        .padding(.vertical, 40)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: overArtwork)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loaded(let lyrics):
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let position = playbackPosition(at: context.date) + leadTime
                LyricsScrollContent(
                    lyrics: lyrics,
                    activeIndex: lyrics.activeIndex(at: position),
                    fontSize: fontSize,
                    height: height,
                    onSeek: { seek(to: $0) }
                )
                .equatable()
            }
        case .loading:
            LyricsSkeleton(fontSize: fontSize)
        case .idle, .unavailable:
            EmptyView()
        }
    }
}

private struct LyricsScrollContent: View, Equatable {
    let lyrics: SyncedLyrics
    let activeIndex: Int?
    let fontSize: CGFloat
    let height: CGFloat
    let onSeek: (TimeInterval) -> Void

    static func == (lhs: LyricsScrollContent, rhs: LyricsScrollContent) -> Bool {
        lhs.lyrics == rhs.lyrics && lhs.activeIndex == rhs.activeIndex &&
        lhs.fontSize == rhs.fontSize && lhs.height == rhs.height
    }

    private var scrollTarget: Int { max(activeIndex ?? 0, 0) }

    /// True while the user is scrolling the lyrics themselves: blur lifts so
    /// every line is readable, and auto-follow pauses until they go idle.
    @State private var isBrowsing = false
    @State private var scrollMonitor: Any?
    @State private var resumeTask: Task<Void, Never>?
    private let browseIdleDelay: Duration = .seconds(3)

    private func noteUserScroll(_ proxy: ScrollViewProxy) {
        isBrowsing = true
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: browseIdleDelay)
            guard !Task.isCancelled else { return }
            isBrowsing = false
        }
    }

    private func installScrollMonitor(_ proxy: ScrollViewProxy) {
        guard scrollMonitor == nil, lyrics.isSynced else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: window.frame.height - event.locationInWindow.y)
            if LyricsHitRegions.shared.columnFrame.contains(point) { noteUserScroll(proxy) }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        resumeTask?.cancel()
        resumeTask = nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: fontSize * 0.7) {
                    ForEach(lyrics.lines) { line in
                        LyricLineRow(
                            line: line,
                            fontSize: fontSize,
                            // nil = unsynced: no highlight, no depth effect.
                            distance: lyrics.isSynced ? line.id - (activeIndex ?? -1) : nil,
                            isBrowsing: isBrowsing,
                            onSeek: onSeek
                        )
                        .id(line.id)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: LineFramesKey.self,
                                    value: [line.id: proxy.frame(in: .named("widgetRootSpace"))]
                                )
                            }
                        )
                    }
                }
                .onPreferenceChange(LineFramesKey.self) { LyricsHitRegions.shared.lineFrames = $0 }
                .padding(.horizontal, 8)
                // Half a viewport of padding each side lets the first and last
                // lines still reach the centre.
                .padding(.vertical, height / 2)
            }
            .onAppear {
                LyricsHitRegions.shared.onLineTap = { id in
                    if lyrics.lines.indices.contains(id), let time = lyrics.lines[id].time { onSeek(time) }
                }
                installScrollMonitor(proxy)
                DispatchQueue.main.async { proxy.scrollTo(scrollTarget, anchor: .center) }
            }
            .onDisappear { removeScrollMonitor() }
            // Recentre from here rather than from the idle Task: that closure
            // captured the view as it was when scrolling began, so its
            // activeIndex is stale and it scrolled to an old line.
            .onChange(of: isBrowsing) { _, browsing in
                guard !browsing else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
            }
            .onChange(of: activeIndex) { _, _ in
                // Don't yank the view away while the user is reading ahead;
                // it recentres once they stop scrolling.
                guard lyrics.isSynced, !isBrowsing else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
            }
        }
    }
}

private struct LyricLineRow: View {
    let line: SyncedLyricLine
    let fontSize: CGFloat
    /// Signed offset from the active line; nil when lyrics aren't synced.
    let distance: Int?
    let isBrowsing: Bool
    let onSeek: (TimeInterval) -> Void

    private var isActive: Bool { distance == 0 }
    private var clamped: Int { min(abs(distance ?? 0), 4) }

    @State private var isHovering = false
    private var isSeekable: Bool { line.time != nil }

    private var opacity: Double {
        guard distance != nil else { return 0.8 }
        if isActive { return 1 }
        // Hovering a seekable line brings it forward so it reads as clickable.
        if isHovering && isSeekable { return 0.85 }
        if isBrowsing { return 0.6 }
        return max(0.18, 0.5 - Double(clamped) * 0.08)
    }

    /// Grows with distance from the active line (like Apple Music); lifted
    /// entirely while scrolling or hovering so any line can be read.
    private var blur: CGFloat {
        guard distance != nil, !isActive, !isBrowsing, !(isHovering && isSeekable) else { return 0 }
        return CGFloat(clamped) * 1.1
    }

    var body: some View {
        Text(line.text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Scale rather than resize the font so the active line doesn't
            // re-wrap and shove every other line's position around.
            .scaleEffect(distance == nil || isActive ? 1 : 0.88, anchor: .leading)
            .opacity(opacity)
            .blur(radius: blur)
            .animation(.easeInOut(duration: 0.45), value: distance)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.25), value: isBrowsing)
            .contentShape(Rectangle())
            .onTapGesture {
                if let time = line.time { onSeek(time) }
            }
            .onHover { inside in
                isHovering = inside
                guard isSeekable else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHovering { NSCursor.pop() }
            }
    }
}

private struct LyricsSkeleton: View {
    let fontSize: CGFloat
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.7) {
            ForEach(Array([0.6, 0.85, 0.95, 0.7, 0.5].enumerated()), id: \.offset) { index, fraction in
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(index == 2 ? 0.32 : 0.16))
                        .frame(width: proxy.size.width * fraction, height: fontSize * 0.8)
                }
                .frame(height: fontSize * 0.8)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .center)
        .opacity(pulsing ? 0.45 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
        }
    }
}
