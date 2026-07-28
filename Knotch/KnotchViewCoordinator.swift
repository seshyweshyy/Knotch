//
//  KnotchViewCoordinator.swift
//  Knotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
    case bluetoothAudio
    case focusMode
    case airdropReceive
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
    var deviceName: String = ""  // Bluetooth device name, Focus status text ("On"/"Off"), or AirDrop received file's full path
    var accentColor: Color = .white  // Used for Focus HUD
}

// Fired once per toggleSneakPeek call that lands exactly on a HUD limit (0 or 1),
// not just when the value first crosses into it — so repeated key presses while
// already pinned at max/min each get their own bounce. `id` always increments so
// SwiftUI's onChange refires even when consecutive events share the same edge.
struct HUDLimitBounceEvent: Equatable {
    var id: Int = 0
    var rightEdge: Bool = false
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class KnotchViewCoordinator: ObservableObject {
    static let shared = KnotchViewCoordinator()

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    @Published var hudLimitBounceEvent = HUDLimitBounceEvent()
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""
    @Published var isScreenLocked: Bool = false

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform one-time migration of the old single sneak-peek toggle into the
        // two new track-change / resume toggles, so users who had it enabled don't
        // silently lose the behavior.
        if !Defaults[.hasMigratedSneakPeekSplit] {
            if Defaults[.legacyEnableSneakPeek] {
                Defaults[.sneakPeekOnTrackChange] = true
                Defaults[.sneakPeekOnResume] = true
            }
            Defaults[.hasMigratedSneakPeekSplit] = true
        }

        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.hudReplacement] {
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 2, value: CGFloat = 0,
        icon: String = "", isRepeat: Bool = false
    ) {
        sneakPeekDuration = duration
        if type != .music && type != .bluetoothAudio {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if status, !isRepeat, type == .volume || type == .brightness, value <= 0 || value >= 1 {
            hudLimitBounceEvent = HUDLimitBounceEvent(id: hudLimitBounceEvent.id + 1, rightEdge: value >= 1)
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }
    
    func toggleBluetoothSneakPeek(deviceName: String, icon: String, batteryLevel: Int) {
        // value encodes battery: -1 = unknown, 0–100 = percentage
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = true
                self.sneakPeek.type = .bluetoothAudio
                self.sneakPeek.value = batteryLevel >= 0 ? CGFloat(batteryLevel) / 100.0 : -1
                self.sneakPeek.icon = icon
                self.sneakPeek.deviceName = deviceName
            }
        }
        // Total duration: compact(0.8) + expanded(2.7) + compact(0.8) = 4.3s
        sneakPeekDuration = 5.0
    }

    /// `statusText` is literal display text ("On"/"Off"), not the Focus mode's name.
    func toggleFocusModeSneakPeek(statusText: String, icon: String, tintColor: Color) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = true
                self.sneakPeek.type = .focusMode
                self.sneakPeek.icon = icon
                self.sneakPeek.deviceName = statusText
                self.sneakPeek.accentColor = tintColor
            }
        }
        sneakPeekDuration = 3.0
    }

    /// Called once when a new incoming transfer is first detected. Progress
    /// starts at 0 and is streamed in via `updateAirDropReceiveProgress`.
    func toggleAirDropReceiveSneakPeek() {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = true
                self.sneakPeek.type = .airdropReceive
                self.sneakPeek.value = 0
                self.sneakPeek.icon = "airdrop"
                self.sneakPeek.deviceName = ""
            }
        }
        sneakPeekDuration = 2.0
    }

    /// Streamed continuously as real bytes arrive; each call pushes the
    /// auto-hide timer forward so the HUD stays open for exactly the
    /// duration of the transfer, plus a short grace period after it stops.
    func updateAirDropReceiveProgress(_ progress: CGFloat) {
        guard sneakPeek.type == .airdropReceive else { return }
        sneakPeekDuration = 2.0
        Task { @MainActor in
            self.sneakPeek.value = min(max(progress, 0), 1)
        }
    }

    /// Transfer finished successfully — pins progress at 100% and reveals
    /// the resolved file path, then lingers longer before auto-closing so
    /// the completed card is actually readable.
    func completeAirDropReceive(filePath: String) {
        guard sneakPeek.type == .airdropReceive else { return }
        // Must outlast AirDropReceiveHUD's own expanded-phase timer (4s) plus
        // its brief collapsing checkmark phase, or the outer timer here would
        // yank the whole HUD away mid-display.
        sneakPeekDuration = 5.5
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.value = 1.0
                self.sneakPeek.deviceName = filePath
            }
        }
    }

    /// Transfer went away without finishing (declined/failed/cancelled) —
    /// close immediately rather than showing a false "complete" state.
    func cancelAirDropReceive() {
        guard sneakPeek.type == .airdropReceive else { return }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = false
            }
        }
    }


    private var sneakPeekDuration: TimeInterval = 2
    private var sneakPeekTask: Task<Void, Never>?
    private var sneakPeekHideDeadline: Date?
    private var sneakPeekPausedRemaining: TimeInterval?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()
        sneakPeekPausedRemaining = nil
        sneakPeekHideDeadline = Date().addingTimeInterval(duration)

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 2
                }
            }
        }
    }

    /// Freezes the auto-hide countdown at its current remaining time. Call
    /// `resumeSneakPeekAutoHide()` to continue from where it left off —
    /// this pauses, it doesn't restart. No-op if already paused or nothing
    /// is scheduled.
    func pauseSneakPeekAutoHide() {
        guard sneakPeekTask != nil, sneakPeekPausedRemaining == nil else { return }
        let remaining = sneakPeekHideDeadline?.timeIntervalSinceNow ?? 0
        sneakPeekPausedRemaining = max(0.1, remaining)
        sneakPeekTask?.cancel()
        sneakPeekTask = nil
    }

    func resumeSneakPeekAutoHide() {
        guard let remaining = sneakPeekPausedRemaining else { return }
        sneakPeekPausedRemaining = nil
        scheduleSneakPeekHide(after: remaining)
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }
}
