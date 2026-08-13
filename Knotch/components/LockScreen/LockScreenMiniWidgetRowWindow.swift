//
//  LockScreenMiniWidgetRowWindow.swift
//  Knotch
//
//  A row of small pill widgets (battery, connectivity, focus, calendar,
//  weather) shown under the clock on the lock screen — Knotch's own
//  recreation of macOS's native lock-screen widget row, not a mirror of it.
//  Reuses the generic LiquidGlassWidgetWindow (KnotchSkyLightWindow-backed,
//  click-through, SkyLight-delegated) the same way the timer widget does,
//  rather than a bespoke window subclass — see LiquidGlassTimerWidgetWindow.swift.
//
//  Usage (from KnotchApp):
//    LockScreenMiniWidgetRowWindowController.shared.screenDidLock(on: screen)
//    LockScreenMiniWidgetRowWindowController.shared.screenDidUnlock()
//

import AlbumArtBackgroundWindow
import AppKit
import Combine
import Defaults
import SwiftUI

/// How the mini-widget row renders each pill. `.glassCapsules` uses
/// KnotchLiquidGlass with adaptiveAppearance: true (see that file), which
/// is confirmed necessary (though not yet confirmed sufficient on its own)
/// for the glass to track the system Liquid Glass Clear/Tinted setting.
/// `.floatingText` remains as a fallback that doesn't depend on any
/// backdrop material at all.
enum MiniWidgetAppearanceStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case glassCapsules = "Glass Capsules"
    case floatingText = "Floating Text"
    var id: String { rawValue }
}

// MARK: - Root SwiftUI host

private struct LockScreenMiniWidgetRowRoot: View {
    @ObservedObject var battery = BatteryStatusViewModel.shared
    @ObservedObject var bluetooth = BluetoothAudioManager.shared
    @ObservedObject var focus = FocusModeManager.shared
    @ObservedObject var calendarManager = CalendarManager.shared
    @ObservedObject var weather = WeatherManager.shared

    @Default(.lockScreenBatteryMiniWidget) var batteryEnabled
    @Default(.lockScreenMiniWidgetBatteryMetric) var batteryMetric
    @Default(.lockScreenConnectivityMiniWidget) var connectivityEnabled
    @Default(.lockScreenFocusMiniWidget) var focusEnabled
    @Default(.lockScreenCalendarMiniWidget) var calendarEnabled
    @Default(.lockScreenWeatherMiniWidget) var weatherEnabled
    @Default(.lockScreenMiniWidgetWeatherMetric) var weatherMetric
    @Default(.lockScreenMiniWidgetAppearance) var appearance

    // Tunable — the real lock screen clock's vertical position varies
    // slightly by macOS version/wallpaper, so this offset (distance from the
    // top of the screen to the top of the row) is a first guess; nudge it
    // once it's visible on the real lock screen.
    private static let topOffset: CGFloat = 250

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer().frame(height: Self.topOffset)
                if hasAnyPill {
                    // Floating Text pills carry the same padding as Glass
                    // Capsules (added so the text itself reads at a matching
                    // size — see LockScreenMiniWidgetPill), but that padding
                    // is invisible without a capsule boundary, so the same
                    // HStack spacing on top of it reads as a much bigger gap
                    // between widgets than intended. Pulling it negative
                    // cancels most of that padding back out for this mode.
                    HStack(spacing: appearance == .floatingText ? -12 : 8) {
                        if batteryEnabled {
                            LockScreenMiniWidgetPill(
                                systemImage: batteryIconName,
                                text: batteryText
                            )
                        }
                        if connectivityEnabled, let device = bluetooth.connectedDevice {
                            LockScreenMiniWidgetPill(
                                systemImage: device.icon,
                                text: connectivityText(for: device)
                            )
                        }
                        if focusEnabled, focus.isActive {
                            LockScreenMiniWidgetPill(
                                systemImage: focus.activeSymbolName ?? "moon.fill",
                                text: focus.activeName ?? "Focus"
                            )
                        }
                        if calendarEnabled, let event = nextUpcomingEvent {
                            LockScreenMiniWidgetPill(
                                systemImage: "calendar",
                                text: calendarText(for: event)
                            )
                        }
                        if weatherEnabled, let snapshot = weather.snapshot {
                            LockScreenMiniWidgetPill(
                                systemImage: weatherIcon(for: snapshot),
                                text: weatherText(for: snapshot)
                            )
                        }
                    }
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .frame(width: geo.size.width)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: hasAnyPill)
    }

    private var hasAnyPill: Bool {
        batteryEnabled
            || (connectivityEnabled && bluetooth.connectedDevice != nil)
            || (focusEnabled && focus.isActive)
            || (calendarEnabled && nextUpcomingEvent != nil)
            || (weatherEnabled && weather.snapshot != nil)
    }

    /// The next event today that hasn't started yet. CalendarManager only
    /// keeps today's events loaded (its "week" fetch is actually a single
    /// day), so this only looks ahead within today, not future days.
    private var nextUpcomingEvent: EventModel? {
        calendarManager.events
            .filter { !$0.type.isReminder && $0.eventStatus == .upcoming }
            .sorted { $0.start < $1.start }
            .first
    }

    private var batteryIconName: String {
        if battery.isCharging { return "bolt.fill" }
        if battery.isPluggedIn { return "powerplug.portrait.fill" }
        return "battery.100"
    }

    private var batteryText: String {
        if battery.isPluggedIn && !battery.isCharging && battery.levelBattery >= battery.maxCapacity {
            return "Fully Charged"
        }
        switch batteryMetric {
        case .percentage:
            return "\(Int(battery.levelBattery))%"
        case .timeRemaining:
            if battery.isCharging {
                return Self.formattedDuration(minutes: battery.timeToFullCharge, suffix: "until full")
            }
            if battery.isPluggedIn {
                return "Plugged In"
            }
            return Self.formattedDuration(minutes: battery.timeToEmpty, suffix: "left")
        }
    }

    private static func formattedDuration(minutes: Int, suffix: String) -> String {
        guard minutes > 0 else { return "Calculating…" }
        let hours = minutes / 60
        let mins = minutes % 60
        switch (hours > 0, mins > 0) {
        case (true, true):
            return "\(hours)h \(mins)m \(suffix)"
        case (true, false):
            return "\(hours)h \(suffix)"
        default:
            return "\(mins)m \(suffix)"
        }
    }

    private func connectivityText(for device: ConnectedBluetoothDevice) -> String {
        guard let level = device.batteryLevel else { return device.name }
        return "\(device.name) \(level)%"
    }

    private func calendarText(for event: EventModel) -> String {
        if event.isAllDay {
            return event.title
        }
        return "\(Self.timeFormatter.string(from: event.start).lowercased()) \(event.title)"
    }

    private func weatherIcon(for snapshot: WeatherSnapshot) -> String {
        switch weatherMetric {
        case .conditions: return snapshot.conditionSymbol
        case .sun: return "sunrise.fill"
        case .precipitation: return "umbrella.fill"
        }
    }

    private func weatherText(for snapshot: WeatherSnapshot) -> String {
        switch weatherMetric {
        case .conditions:
            return "\(Int(round(snapshot.temperatureC)))°"
        case .sun:
            return Self.timeFormatter.string(from: snapshot.sunriseDate).lowercased()
        case .precipitation:
            return "AQI \(snapshot.aqi) \(snapshot.aqiLabel)"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

/// One pill: icon + text. `.glassCapsules` styles it to match
/// LiquidGlassMusicWidget's dark frosted look; `.floatingText` drops the
/// capsule/material entirely and just lays the content straight over the
/// wallpaper at reduced opacity, with a soft shadow for legibility.
private struct LockScreenMiniWidgetPill: View {
    let systemImage: String
    let text: String
    @Default(.lockScreenMiniWidgetAppearance) private var appearance

    var body: some View {
        Group {
            switch appearance {
            case .glassCapsules:
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(pillBackground)
                    .environment(\.controlActiveState, .active)
            case .floatingText:
                // Same padding as the glass-capsule case (just no
                // capsule/material behind it) — without it the text has no
                // surrounding whitespace to read against, which makes the
                // exact same font size look larger than the capsule version
                // by comparison.
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .opacity(0.75)
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            }
        }
        .foregroundStyle(.white)
    }

    private var content: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
            Text(text)
                .font(.system(size: 14, weight: .semibold))
        }
    }

    @ViewBuilder
    private var pillBackground: some View {
        if #available(macOS 26.0, *) {
            // adaptiveAppearance: true, style: 0 (.regular) — see
            // KnotchLiquidGlass.swift and LiquidGlassMusicWidget.swift's
            // matching usage.
            KnotchLiquidGlass(shape: .capsule, adaptiveAppearance: true, style: 0)
        } else {
            Capsule()
                .fill(.thickMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(Capsule().fill(Color.black.opacity(0.25)))
        }
    }
}

// MARK: - Controller

private final class FirstMouseMiniWidgetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class LockScreenMiniWidgetRowWindowController {
    static let shared = LockScreenMiniWidgetRowWindowController()

    private var window: LiquidGlassWidgetWindow?
    private var isScreenLocked = false
    // The expanded album art (LiquidGlassWidgetWindow.swift) sits at the
    // same window level as this row and gets brought to front independently,
    // so it can end up layered either above or below the pills depending on
    // ordering — visibly colliding with them (see screenshot: the battery
    // pill peeking out from behind the art). Hiding the row while art is
    // expanded sidesteps needing to referee window ordering between two
    // separately-controlled windows at the same level. Reuses the
    // hide/show notifications LiquidGlassWidgetWindow already posts on
    // expand/collapse — declared in the AlbumArtBackgroundWindow package,
    // originally for a lock-screen profile picture nothing currently
    // observes, but the posting already fires at exactly the right moments.
    private var isAlbumArtExpanded = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        Publishers.MergeMany(
            BatteryStatusViewModel.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            BluetoothAudioManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            FocusModeManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            WeatherManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .lockScreenProfileShouldHide)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isAlbumArtExpanded = true
                self?.refresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .lockScreenProfileShouldShow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isAlbumArtExpanded = false
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func screenDidLock(on screen: NSScreen) {
        isScreenLocked = true
        WeatherManager.shared.refreshIfNeeded()
        // CalendarManager.events only ever gets fetched when the notch's own
        // calendar view or the Settings Calendar tab has appeared — neither
        // of which this widget depends on — so without this it can sit
        // permanently empty and the Calendar pill never has anything to show.
        if Defaults[.lockScreenCalendarMiniWidget] {
            Task { @MainActor in
                CalendarManager.shared.scheduleUpdate(for: Date())
            }
        }
        refresh(preferredScreen: screen)
    }

    func screenDidUnlock() {
        isScreenLocked = false
        refresh()
    }

    func updateScreen(_ screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
    }

    private func refresh(preferredScreen: NSScreen? = nil) {
        let anyWidgetEnabled = Defaults[.lockScreenMiniWidgetsEnabled] && (
            Defaults[.lockScreenBatteryMiniWidget]
            || Defaults[.lockScreenConnectivityMiniWidget]
            || Defaults[.lockScreenFocusMiniWidget]
            || Defaults[.lockScreenCalendarMiniWidget]
            || Defaults[.lockScreenWeatherMiniWidget]
        )

        guard isScreenLocked, anyWidgetEnabled, !isAlbumArtExpanded else {
            hide()
            return
        }
        show(on: preferredScreen ?? window?.screen ?? NSScreen.main ?? NSScreen.screens[0])
    }

    private func show(on screen: NSScreen) {
        if window == nil {
            let win = LiquidGlassWidgetWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.contentView = FirstMouseMiniWidgetHostingView(rootView: LockScreenMiniWidgetRowRoot())
            win.setClickThrough(true)
            // See LiquidGlassWidgetWindowController.show's matching comment.
            win.setValue(false, forKey: "shouldAutoFlattenLayerTree")
            win.setValue(false, forKey: "canHostLayersInWindowServer")
            win.setValue(true, forKey: "canHostLayersInWindowServer")
            window = win
        }

        guard let win = window else { return }
        win.setFrame(screen.frame, display: false)
        win.enableSkyLight()
        win.orderFrontRegardless()
        // See LiquidGlassWidgetWindowController.show's matching comment —
        // holds key/main persistently since this window only exists while
        // the screen is locked.
        win.makeKey()
        win.makeMain()
    }

    // See LiquidGlassWidgetWindowController.hide's matching comment — fully
    // destroys the window instead of just hiding it, so every lock gets a
    // freshly-created NSGlassEffectView that correctly reads the current
    // system Clear/Tinted setting at creation time, rather than reusing a
    // stale instance from an earlier lock that no longer updates.
    private func hide() {
        guard let win = window else { return }
        win.disableSkyLight()
        win.orderOut(nil)
        win.contentView = nil
        window = nil
    }
}
