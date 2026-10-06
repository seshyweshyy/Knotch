//
//  FocusModeManager.swift
//  Knotch
//

import AppKit
import Combine
import CoreServices
import Defaults
import SwiftUI

/// Detects when a macOS Focus mode (Do Not Disturb, Work, custom modes, etc.)
/// turns on or off, and resolves its name, SF Symbol icon, and accent colour —
/// all without Full Disk Access.
///
/// Three sources are combined:
/// - `DistributedNotificationCenter` posts `_NSDoNotDisturbEnabledNotification` /
///   `_NSDoNotDisturbDisabledNotification` on some macOS versions. No
///   entitlement is required, but recent macOS releases do not reliably post
///   them when Focus is toggled from Control Centre.
/// - An FSEvents watch on `~/Library/DoNotDisturb/DB` fires within a few
///   milliseconds of `Assertions.json` being rewritten. FSEvents works without
///   Full Disk Access (the file itself is never read) and costs nothing while
///   Focus is idle — there is no polling.
/// - `donotdisturbd` logs a full `<DNDMode: name: ...; symbolImageName: ...;
///   tintColorName: ...>` description about 3ms after it rewrites
///   `Assertions.json`, which is too soon for anything started in reaction to
///   the file event to catch (`log show` alone costs ~0.7s). Knotch therefore
///   keeps one `log stream --process donotdisturbd` attached. The process
///   filter is applied by logd, so it receives nothing but that quiet daemon's
///   lines and sits idle (≈0 CPU) — unlike the former broad predicate stream.
///   If the stream ever misses a transition, the file event triggers a
///   one-shot `log show` after a short grace period.
@MainActor
final class FocusModeManager: ObservableObject {
    static let shared = FocusModeManager()

    /// Persistent current-state mirror of the toast-oriented logic below,
    /// for consumers (e.g. the lock-screen mini-widget row) that need to
    /// read "is Focus on right now" instead of reacting to one-off transitions.
    @Published private(set) var isActive: Bool = false
    @Published private(set) var activeName: String?
    @Published private(set) var activeSymbolName: String?
    @Published private(set) var activeTintColor: Color?

    private let notificationCenter = DistributedNotificationCenter.default()
    private let logQueue = DispatchQueue(label: "com.knotch.focus.logstream", qos: .utility)

    private var isMonitoring = false
    private var enabledCancellable: AnyCancellable?
    private var detailCancellable: AnyCancellable?
    private var fsEventStream: FSEventStreamRef?
    private let fsEventQueue = DispatchQueue(label: "com.knotch.focus.fsevents", qos: .utility)
    /// Long-lived, logd-filtered `log stream` for the daemon. Main-actor only.
    private var liveLookup: Process?
    private var lookupGeneration = 0
    private var handledTransitionKeys: [String] = []
    private var lastStoreEventDate: Date?

    /// The active state we last showed a toast for. `nil` means we haven't
    /// presented anything yet (e.g. right after launch). Comparing against
    /// this — rather than a one-shot "have we shown it" flag — is what makes
    /// re-arming symmetric across successive on/off notifications.
    private var lastPresentedActiveState: Bool?
    private var fallbackPresentTask: DispatchWorkItem?

    private var currentName: String?
    private var currentSymbolName: String?
    private var currentTintColor: Color?

    nonisolated private static let assertionsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json").path

    private init() {
        enabledCancellable = Defaults.publisher(.showFocusModeIndicator, options: [])
            .sink { [weak self] change in
                Task { @MainActor in
                    if change.newValue {
                        self?.startMonitoring()
                    } else {
                        self?.stopMonitoring()
                    }
                }
            }

        detailCancellable = Defaults.publisher(.useDetailedFocusMetadata, options: [])
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self, self.isMonitoring else { return }
                    if change.newValue {
                        self.seedInitialState()
                    }
                }
            }

        // Start explicitly rather than relying on a synchronous `.initial`
        // publisher emission while this singleton is still being initialized.
        if Defaults[.showFocusModeIndicator] {
            startMonitoring()
        }
    }

    // MARK: - Lifecycle

    private func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        print("[Focus] Monitoring started (detailed metadata: \(Defaults[.useDetailedFocusMetadata] ? "on" : "off"))")

        notificationCenter.addObserver(
            self,
            selector: #selector(handleFocusEnabled(_:)),
            name: .focusModeEnabled,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleFocusDisabled(_:)),
            name: .focusModeDisabled,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        startFocusStoreWatcher()
        startLiveLookup()

        if Defaults[.useDetailedFocusMetadata] {
            seedInitialState()
        }
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        print("[Focus] Monitoring stopped")

        notificationCenter.removeObserver(self, name: .focusModeEnabled, object: nil)
        notificationCenter.removeObserver(self, name: .focusModeDisabled, object: nil)

        stopFocusStoreWatcher()
        stopLiveLookup()
        fallbackPresentTask?.cancel()
        fallbackPresentTask = nil
        lastPresentedActiveState = nil
        currentName = nil
        currentSymbolName = nil
        currentTintColor = nil
    }

    // MARK: - Notification handlers

    // All of the `current*`/`lastPresentedActiveState`/`fallbackPresentTask`
    // state below is main-thread-only. The log lookup queue only ever hands
    // parsed results to `applyModeBegin`/`applyModeEnd` via `DispatchQueue.main`.

    @objc nonisolated private func handleFocusEnabled(_ notification: Notification) {
        print("[Focus] _NSDoNotDisturbEnabledNotification received")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fallbackPresentTask?.cancel()

            guard Defaults[.useDetailedFocusMetadata] else {
                self.presentTransition(active: true)
                return
            }

            self.fetchRecentFocusTransition()

            // The log-stream line for this same transition usually lands within
            // a few milliseconds — give it a brief head start so the toast shows
            // the real name/icon/colour instead of the generic fallback. If it
            // hasn't arrived in time, present with whatever's known anyway.
            let task = DispatchWorkItem { [weak self] in self?.presentTransition(active: true) }
            self.fallbackPresentTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
        }
    }

    @objc nonisolated private func handleFocusDisabled(_ notification: Notification) {
        print("[Focus] _NSDoNotDisturbDisabledNotification received")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fallbackPresentTask?.cancel()
            self.fallbackPresentTask = nil
            // The "off" toast always uses whatever icon is currently known
            // (the mode that just ended), so present before clearing it.
            self.presentTransition(active: false)
            self.currentName = nil
            self.currentSymbolName = nil
            self.currentTintColor = nil
            self.activeName = nil
            self.activeSymbolName = nil
            self.activeTintColor = nil
            self.isActive = false
        }
    }

    /// Main-thread only. Shows the "On"/"Off" toast, but only once per
    /// transition — `lastPresentedActiveState` guards against the
    /// notification and the metadata lookup for the *same* transition both
    /// triggering a toast.
    private func presentTransition(active: Bool) {
        guard lastPresentedActiveState != active else { return }
        lastPresentedActiveState = active

        let symbolName = currentSymbolName ?? "moon.fill"
        let tintColor = active ? (currentTintColor ?? .indigo) : .gray
        print("[Focus] Presenting toast -> active: \(active), icon: \(symbolName)")

        Task { @MainActor in
            KnotchViewCoordinator.shared.toggleFocusModeSneakPeek(
                statusText: active ? "On" : "Off",
                icon: symbolName,
                tintColor: tintColor
            )
        }
    }

    /// Main-thread only. Applies a parsed "mode begin" line from a log lookup.
    private func applyModeBegin(_ mode: ParsedDNDMode) {
        print("[Focus] Log stream: mode begin -> name: \(mode.name ?? "nil"), symbolImageName: \(mode.symbolName ?? "nil"), tintColor: \(mode.tintColor.map(String.init(describing:)) ?? "nil")")
        currentName = mode.name
        currentSymbolName = mode.symbolName
        currentTintColor = mode.tintColor
        activeName = mode.name
        activeSymbolName = mode.symbolName
        activeTintColor = mode.tintColor
        isActive = true
        fallbackPresentTask?.cancel()
        presentTransition(active: true)
    }

    /// Applies a detected mode-end event. The log entry still contains the
    /// mode that just ended, so preserve its icon for the Off toast before
    /// clearing persistent state.
    private func applyModeEnd(_ mode: ParsedDNDMode?) {
        if Defaults[.useDetailedFocusMetadata], let mode {
            currentName = mode.name
            currentSymbolName = mode.symbolName
            currentTintColor = mode.tintColor
        }
        print("[Focus] Log lookup: mode end")
        presentTransition(active: false)
        currentName = nil
        currentSymbolName = nil
        currentTintColor = nil
        activeName = nil
        activeSymbolName = nil
        activeTintColor = nil
        isActive = false
    }

    /// Main-thread only. Silently seeds state from the one-shot lookback
    /// without presenting a toast — Focus may have already been active
    /// before Knotch launched. Still records the state so the *next* real
    /// transition (turning it off) correctly triggers an "Off" toast.
    private func applySeededState(_ mode: ParsedDNDMode) {
        print("[Focus] Seeded initial state from log history -> name: \(mode.name ?? "nil"), symbolImageName: \(mode.symbolName ?? "nil")")
        currentName = mode.name
        currentSymbolName = mode.symbolName
        currentTintColor = mode.tintColor
        activeName = mode.name
        activeSymbolName = mode.symbolName
        activeTintColor = mode.tintColor
        isActive = true
        lastPresentedActiveState = true
    }

    // MARK: - One-shot log lookup (name / icon / colour, no FDA)

    nonisolated private static let logPredicate = #"process == "donotdisturbd" AND eventMessage CONTAINS "Biome event(s) donated for mode""#

    // MARK: - File watcher + live lookup

    /// Recent macOS versions do not reliably post the distributed
    /// notifications, so watch the Focus database directory instead. FSEvents
    /// delivers `Assertions.json` writes immediately and needs no entitlement.
    private func startFocusStoreWatcher() {
        guard fsEventStream == nil else { return }
        let directory = (Self.assertionsPath as NSString).deletingLastPathComponent
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            focusStoreEventCallback,
            &context,
            [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            flags
        ) else {
            print("[Focus] Could not create FSEvents stream for \(directory)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, fsEventQueue)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    private func stopFocusStoreWatcher() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }

    /// Main-thread only. `Assertions.json` was rewritten, so Focus changed (or
    /// is about to be logged). Catch the matching daemon log line right away.
    fileprivate func focusStoreDidChange() {
        guard isMonitoring else { return }
        lastStoreEventDate = Date()

        // Safety net: the live stream normally delivers the line within a few
        // milliseconds. If it has not by now, query the recent log once.
        lookupGeneration += 1
        let generation = lookupGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring, self.lookupGeneration == generation else { return }
                self.fetchRecentFocusTransition()
            }
        }
    }

    private func startLiveLookup() {
        guard liveLookup == nil, isMonitoring else { return }
        liveLookup = Self.launchLogStream(
            onLine: { [weak self] line in
                Task { @MainActor [weak self] in self?.handleTransitionLine(line) }
            },
            onExit: { [weak self] in
                Task { @MainActor [weak self] in self?.liveLookupDidExit() }
            }
        )
    }

    /// The stream ended without us stopping it (e.g. logd restarted). Retry
    /// after a pause rather than spinning.
    private func liveLookupDidExit() {
        guard liveLookup != nil else { return }
        liveLookup = nil
        guard isMonitoring else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.startLiveLookup() }
        }
    }

    private func stopLiveLookup() {
        guard let process = liveLookup else { return }
        liveLookup = nil
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Starts `log stream` filtered to the daemon's mode-change line and feeds
    /// each complete line to `onLine` from the pipe's background queue. Kept
    /// `nonisolated` so the handler closure does not inherit main-actor
    /// isolation (it runs on a private queue).
    nonisolated private static func launchLogStream(
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        // `--process` is filtered by logd; the predicate only trims the few
        // remaining daemon lines. The Biome line is a default-level message,
        // so `--debug` is unnecessary.
        process.arguments = [
            "stream", "--process", "donotdisturbd", "--style", "compact",
            "--predicate", #"eventMessage CONTAINS "Biome event(s) donated for mode""#,
        ]
        process.terminationHandler = { _ in onExit() }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in buffer.append(data) { onLine(line) }
        }
        guard (try? process.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        return process
    }

    /// Accumulates pipe chunks and returns only complete lines.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""

        func append(_ data: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            pending += String(decoding: data, as: UTF8.self)
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast()
            return lines
        }
    }

    /// Resolves the transition and optional metadata from the recent log. Used
    /// as a fallback when the live stream did not deliver the line.
    private func fetchRecentFocusTransition() {
        logQueue.async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--last", "10s", "--debug", "--style", "compact", "--predicate", Self.logPredicate]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard let line = output.components(separatedBy: "\n").last(where: {
                $0.contains("Biome event(s) donated for mode")
                    && ($0.contains("mode begin") || $0.contains("mode end"))
            }) else { return }

            Task { @MainActor [weak self] in self?.handleTransitionLine(line) }
        }
    }

    /// Main-thread only. Applies one `Biome event(s) donated for mode begin/end`
    /// line, once, regardless of which lookup delivered it.
    private func handleTransitionLine(_ line: String) {
        guard isMonitoring,
              line.contains("Biome event(s) donated for mode"),
              line.contains("mode begin") || line.contains("mode end") else { return }

        // The compact style starts every line with a unique microsecond
        // timestamp, which is enough to de-duplicate across lookups.
        let key = String(line.prefix(32))
        guard !handledTransitionKeys.contains(key) else { return }
        handledTransitionKeys.append(key)
        if handledTransitionKeys.count > 8 { handledTransitionKeys.removeFirst() }

        // A line has been handled, so the pending fallback is unnecessary.
        lookupGeneration += 1

        if let lastStoreEventDate {
            let ms = Int(Date().timeIntervalSince(lastStoreEventDate) * 1000)
            print("[Focus] Transition line resolved \(ms)ms after file event")
        }

        let mode = parseDNDMode(from: line)
        if line.contains("mode begin") {
            if Defaults[.useDetailedFocusMetadata], let mode {
                applyModeBegin(mode)
            } else {
                isActive = true
                presentTransition(active: true)
            }
        } else {
            applyModeEnd(mode)
        }
    }

    /// One-shot lookback so we know whether Focus was already active when
    /// Knotch launched, before the continuous stream picks up future events.
    private func seedInitialState() {
        logQueue.async { [weak self] in
            print("[Focus] Seeding initial state from log history…")
            for window in ["5m", "1h", "24h"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                process.arguments = ["show", "--last", window, "--debug", "--style", "compact", "--predicate", Self.logPredicate]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                guard (try? process.run()) != nil else { return }
                process.waitUntilExit()

                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let lines = output.components(separatedBy: "\n").filter {
                    $0.contains("Biome event(s) donated for mode") && !$0.hasPrefix("Filtering")
                }

                guard let lastLine = lines.last(where: { !$0.isEmpty }) else { continue }

                if lastLine.contains("mode begin") {
                    Task { @MainActor [weak self] in
                        guard let self, self.isMonitoring, let mode = self.parseDNDMode(from: lastLine) else { return }
                        self.applySeededState(mode)
                    }
                } else {
                    print("[Focus] Seeding: most recent event in last \(window) was a mode end — no Focus currently active")
                }
                return
            }
            print("[Focus] Seeding: no Focus mode activity found in the last 24h")
        }
    }

    // MARK: - `<DNDMode: ...>` parsing

    private struct ParsedDNDMode {
        let name: String?
        let symbolName: String?
        let tintColor: Color?
    }

    /// Pulls `name`, `symbolImageName`, and `tintColorName` out of a trailing
    /// `<DNDMode: 0x...; name: Locked In; modeIdentifier: ...; symbolImageName:
    /// graduationcap.fill; tintColorName: systemOrangeColor; ...>` fragment.
    private func parseDNDMode(from line: String) -> ParsedDNDMode? {
        guard let start = line.range(of: "<DNDMode:") else { return nil }
        let fragment = line[start.lowerBound...]

        func field(_ key: String) -> String? {
            guard let range = fragment.range(of: "\(key):") else { return nil }
            let rest = fragment[range.upperBound...]
            guard let end = rest.range(of: ";") else { return nil }
            let value = rest[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let name = field("name")
        let reportedSymbolName = field("symbolImageName")
        let tintColorName = field("tintColorName")

        guard name != nil || reportedSymbolName != nil || tintColorName != nil else { return nil }

        return ParsedDNDMode(
            name: name,
            symbolName: Self.renderableSymbolName(for: reportedSymbolName),
            tintColor: tintColorName.flatMap(Self.color(forSystemColorName:))
        )
    }

    /// Focus sometimes reports private glyph identifiers (for example the
    /// custom smiley, `emoji.face.grinning`) that Control Centre renders from
    /// `CoreGlyphsPrivate.bundle`. `FocusSymbolImage` can draw both public and
    /// private names, so keep anything that resolves in either set and return
    /// nil for the rest so the caller uses the moon fallback.
    private static func renderableSymbolName(for reportedName: String?) -> String? {
        guard let reportedName else { return nil }
        let name = reportedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "(null)", name != "null" else { return nil }
        return FocusSymbol.isRenderable(name) ? name : nil
    }

    /// Maps AppKit system colour selector names (`systemOrangeColor`,
    /// `systemIndigoColor`, ...) as reported by `donotdisturbd` to SwiftUI Color.
    private static func color(forSystemColorName name: String) -> Color? {
        let cleaned = name.lowercased()
            .replacingOccurrences(of: "system", with: "")
            .replacingOccurrences(of: "color", with: "")

        switch cleaned {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        default: return nil
        }
    }
}

private extension Notification.Name {
    static let focusModeEnabled = Notification.Name("_NSDoNotDisturbEnabledNotification")
    static let focusModeDisabled = Notification.Name("_NSDoNotDisturbDisabledNotification")
}

// MARK: - FSEvents callback

/// Global function so the C callback carries no actor isolation; it runs on the
/// FSEvents dispatch queue and hops to the main actor explicitly.
private func focusStoreEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    guard paths.contains(where: { $0.hasSuffix("/Assertions.json") }) else { return }
    let manager = Unmanaged<FocusModeManager>.fromOpaque(info).takeUnretainedValue()
    Task { @MainActor in manager.focusStoreDidChange() }
}

// MARK: - Focus glyphs

/// Resolves Focus mode glyphs, including private ones Control Centre draws from
/// `CoreGlyphsPrivate.bundle` (`emoji.face.*` and similar) that
/// `NSImage(systemSymbolName:)` rejects.
@MainActor
enum FocusSymbol {
    private static let privateBundle = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")
    private static var cache: [String: NSImage?] = [:]

    static func isPublic(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func isRenderable(_ name: String) -> Bool {
        isPublic(name) || privateImage(named: name) != nil
    }

    /// A template image for a private glyph, or nil for public/unknown names.
    /// Control Centre shows the solid `.inverse` variant when one exists.
    static func privateImage(named name: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        guard !isPublic(name) else { return nil }
        let key = "\(name)|\(pointSize)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }

        var image: NSImage?
        if let bundle = privateBundle {
            let base = NSImage(symbolName: name + ".inverse", bundle: bundle, variableValue: 1)
                ?? NSImage(symbolName: name, bundle: bundle, variableValue: 1)
            // Draw via a bitmap at 3x. Drawing the symbol straight into a
            // context flattens `.inverse` glyphs to an outline, whereas the
            // bitmap path keeps the solid disc with transparent features.
            let scale: CGFloat = 3
            if let symbol = base?.withSymbolConfiguration(.init(pointSize: pointSize * scale, weight: weight)),
               let tiff = symbol.tiffRepresentation,
               let plain = NSImage(data: tiff) {
                plain.size = NSSize(width: symbol.size.width / scale, height: symbol.size.height / scale)
                plain.isTemplate = true
                image = plain
            }
        }
        cache[key] = image
        return image
    }
}

/// Draws a Focus glyph, public or private, tinted by the surrounding
/// `foregroundStyle`.
struct FocusSymbolImage: View {
    let name: String
    var pointSize: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        if let image = FocusSymbol.privateImage(named: name, pointSize: pointSize, weight: nsWeight) {
            Image(nsImage: image)
                .renderingMode(.template)
        } else {
            // Explicit `.none` keeps public fallbacks without a filled variant
            // visible when an ancestor requests `.fill`.
            Image(systemName: name)
                .font(.system(size: pointSize, weight: weight))
                .symbolVariant(.none)
                .contentTransition(.interpolate)
        }
    }

    private var nsWeight: NSFont.Weight {
        switch weight {
        case .semibold: return .semibold
        case .bold: return .bold
        case .medium: return .medium
        case .light: return .light
        default: return .regular
        }
    }
}
