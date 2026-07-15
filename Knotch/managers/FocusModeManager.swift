//
//  FocusModeManager.swift
//  Knotch
//

import AppKit
import Combine
import Defaults
import SwiftUI

/// Detects when a macOS Focus mode (Do Not Disturb, Work, custom modes, etc.)
/// turns on or off, and resolves its name, SF Symbol icon, and accent colour —
/// all without Full Disk Access.
///
/// Two sources are combined:
/// - `DistributedNotificationCenter` posts `_NSDoNotDisturbEnabledNotification` /
///   `_NSDoNotDisturbDisabledNotification` the instant Focus toggles. No
///   entitlement required, but the notification payload rarely carries a
///   usable name/icon for custom modes.
/// - `donotdisturbd` logs a full `<DNDMode: name: ...; symbolImageName: ...;
///   tintColorName: ...>` description to the unified system log every time a
///   mode begins or ends (category `BiomeDonation`, debug level). That log is
///   not a TCC-protected resource, so tailing it via `/usr/bin/log stream`
///   gives the same icon/colour data Full Disk Access would otherwise be
///   needed for (`~/Library/DoNotDisturb/DB/ModeConfigurations.json`).
final class FocusModeManager {
    static let shared = FocusModeManager()

    private let notificationCenter = DistributedNotificationCenter.default()
    private let logQueue = DispatchQueue(label: "com.knotch.focus.logstream", qos: .utility)

    private var isMonitoring = false
    private var enabledCancellable: AnyCancellable?
    private var detailCancellable: AnyCancellable?

    private var logProcess: Process?
    private var logPipe: Pipe?
    private var logBuffer = Data()
    private var restartWorkItem: DispatchWorkItem?

    /// The active state we last showed a toast for. `nil` means we haven't
    /// presented anything yet (e.g. right after launch). Comparing against
    /// this — rather than a one-shot "have we shown it" flag — is what makes
    /// re-arming symmetric: whichever signal (notification or log line)
    /// reports a transition first wins, and the *next* transition is always
    /// a fresh comparison, so there's no separate "reset" step that can be
    /// skipped if one signal doesn't fire.
    private var lastPresentedActiveState: Bool?
    private var fallbackPresentTask: DispatchWorkItem?

    private var currentName: String?
    private var currentSymbolName: String?
    private var currentTintColor: Color?

    private init() {
        enabledCancellable = Defaults.publisher(.showFocusModeIndicator, options: [.initial])
            .sink { [weak self] change in
                DispatchQueue.main.async {
                    if change.newValue {
                        self?.startMonitoring()
                    } else {
                        self?.stopMonitoring()
                    }
                }
            }

        detailCancellable = Defaults.publisher(.useDetailedFocusMetadata, options: [])
            .sink { [weak self] change in
                guard let self, self.isMonitoring else { return }
                DispatchQueue.main.async {
                    if change.newValue {
                        self.startLogStream()
                    } else {
                        self.stopLogStream()
                    }
                }
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

        if Defaults[.useDetailedFocusMetadata] {
            startLogStream()
        }
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        print("[Focus] Monitoring stopped")

        notificationCenter.removeObserver(self, name: .focusModeEnabled, object: nil)
        notificationCenter.removeObserver(self, name: .focusModeDisabled, object: nil)

        stopLogStream()
        fallbackPresentTask?.cancel()
        fallbackPresentTask = nil
        lastPresentedActiveState = nil
        currentName = nil
        currentSymbolName = nil
        currentTintColor = nil
    }

    // MARK: - Notification handlers

    // All of the `current*`/`lastPresentedActiveState`/`fallbackPresentTask`
    // state below is main-thread-only. The log-stream queue only ever hands
    // parsed results to `applyModeBegin`/`applyModeEnd` via `DispatchQueue.main`.

    @objc private func handleFocusEnabled(_ notification: Notification) {
        print("[Focus] _NSDoNotDisturbEnabledNotification received")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fallbackPresentTask?.cancel()

            guard Defaults[.useDetailedFocusMetadata] else {
                self.presentTransition(active: true)
                return
            }

            // The log-stream line for this same transition usually lands within
            // a few milliseconds — give it a brief head start so the toast shows
            // the real name/icon/colour instead of the generic fallback. If it
            // hasn't arrived in time, present with whatever's known anyway.
            let task = DispatchWorkItem { [weak self] in self?.presentTransition(active: true) }
            self.fallbackPresentTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
        }
    }

    @objc private func handleFocusDisabled(_ notification: Notification) {
        print("[Focus] _NSDoNotDisturbDisabledNotification received")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fallbackPresentTask?.cancel()
            self.fallbackPresentTask = nil
            // The "off" toast always uses whatever icon is currently known
            // (the mode that just ended), so present before clearing it.
            self.presentTransition(active: false)
            self.currentName = nil
            self.currentSymbolName = nil
            self.currentTintColor = nil
        }
    }

    /// Main-thread only. Shows the "On"/"Off" toast, but only once per
    /// transition — `lastPresentedActiveState` guards against the
    /// notification and the log-stream line for the *same* transition both
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

    /// Main-thread only. Applies a parsed "mode begin" line from the log stream.
    private func applyModeBegin(_ mode: ParsedDNDMode) {
        print("[Focus] Log stream: mode begin -> name: \(mode.name ?? "nil"), symbolImageName: \(mode.symbolName ?? "nil"), tintColor: \(mode.tintColor.map(String.init(describing:)) ?? "nil")")
        currentName = mode.name
        currentSymbolName = mode.symbolName
        currentTintColor = mode.tintColor
        fallbackPresentTask?.cancel()
        presentTransition(active: true)
    }

    /// Main-thread only. Applies a parsed "mode end" line from the log stream.
    /// This is also what saves us if `_NSDoNotDisturbDisabledNotification`
    /// fails to fire — a known macOS quirk — since it independently re-arms
    /// `lastPresentedActiveState` for the next "on" transition.
    private func applyModeEnd() {
        print("[Focus] Log stream: mode end")
        presentTransition(active: false)
        currentName = nil
        currentSymbolName = nil
        currentTintColor = nil
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
        lastPresentedActiveState = true
    }

    // MARK: - Log stream (name / icon / colour, no FDA)

    private static let logPredicate = #"process == "donotdisturbd" AND eventMessage CONTAINS "Biome event(s) donated for mode""#

    private func startLogStream() {
        guard logProcess == nil else { return }
        seedInitialState()

        logQueue.async { [weak self] in
            self?.launchLogStreamProcess()
        }
    }

    private func stopLogStream() {
        restartWorkItem?.cancel()
        restartWorkItem = nil

        logQueue.async { [weak self] in
            guard let self else { return }
            self.logPipe?.fileHandleForReading.readabilityHandler = nil
            if self.logProcess?.isRunning == true {
                self.logProcess?.terminate()
            }
            self.logProcess = nil
            self.logPipe = nil
            self.logBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func launchLogStreamProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--debug", "--style", "compact", "--predicate", Self.logPredicate]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.logQueue.async {
                self?.handleIncomingLogData(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.logQueue.async {
                self?.handleLogStreamTermination()
            }
        }

        do {
            try process.run()
            logProcess = process
            logPipe = pipe
            print("[Focus] Log stream started (pid \(process.processIdentifier))")
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            print("[Focus] Failed to start log stream: \(error)")
        }
    }

    private func handleLogStreamTermination() {
        logPipe?.fileHandleForReading.readabilityHandler = nil
        logPipe = nil
        logProcess = nil

        guard isMonitoring, Defaults[.useDetailedFocusMetadata] else { return }
        print("[Focus] Log stream terminated unexpectedly, restarting in 3s")

        let workItem = DispatchWorkItem { [weak self] in
            self?.logQueue.async {
                self?.launchLogStreamProcess()
            }
        }
        restartWorkItem = workItem
        logQueue.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func handleIncomingLogData(_ data: Data) {
        logBuffer.append(data)

        let newline: UInt8 = 0x0A
        while let index = logBuffer.firstIndex(of: newline) {
            let lineData = logBuffer.prefix(upTo: index)
            logBuffer.removeSubrange(logBuffer.startIndex...index)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            processLogLine(line)
        }
    }

    /// One-shot lookback so we know whether Focus was already active when
    /// Knotch launched, before the continuous stream picks up future events.
    private func seedInitialState() {
        logQueue.async { [weak self] in
            guard let self else { return }
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

                if lastLine.contains("mode begin"), let mode = self.parseDNDMode(from: lastLine) {
                    DispatchQueue.main.async {
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

    /// Runs on `logQueue`. Parsing is pure; applying the result is handed off
    /// to the main thread since that's where `current*` state lives.
    private func processLogLine(_ line: String) {
        guard let mode = parseDNDMode(from: line) else { return }

        if line.contains("mode begin") {
            DispatchQueue.main.async { [weak self] in self?.applyModeBegin(mode) }
        } else if line.contains("mode end") {
            DispatchQueue.main.async { [weak self] in self?.applyModeEnd() }
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
        let symbolName = field("symbolImageName")
        let tintColorName = field("tintColorName")

        guard name != nil || symbolName != nil || tintColorName != nil else { return nil }

        return ParsedDNDMode(
            name: name,
            symbolName: symbolName,
            tintColor: tintColorName.flatMap(Self.color(forSystemColorName:))
        )
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
