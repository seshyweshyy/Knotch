//
//  LockScreenMiniWidgetsSection.swift
//  Knotch
//
//  Settings UI for the lock-screen mini-widget row (LockScreenMiniWidgetRowWindow):
//  a grouped toggle list (Battery/Connectivity/Focus/Calendar) styled like the
//  existing SettingsSidebarIcon badges, plus a segmented preview-card picker
//  for which weather metric to show.
//

import Defaults
import SwiftUI

/// Loads the current desktop wallpaper once and shares it across every
/// mini-widget preview card below, the same source NotchStylePreview uses
/// for the notch appearance cards (NSWorkspace.desktopImageURL), just cached
/// once instead of per-card since several cards render at once here.
private final class MiniWidgetPreviewWallpaper: ObservableObject {
    static let shared = MiniWidgetPreviewWallpaper()
    @Published private(set) var image: NSImage?

    private init() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        image = NSImage(contentsOf: url)
    }
}

/// Wallpaper-backed card background shared by the battery/weather preview
/// cards: the real photo, dimmed for legibility, with the selection border
/// on top — mirrors NotchStylePreview's wallpaper + darkening treatment.
private struct MiniWidgetPreviewCardBackground: View {
    @ObservedObject private var wallpaper = MiniWidgetPreviewWallpaper.shared
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.gray.opacity(0.3))
            .overlay {
                if let image = wallpaper.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 4)
                }
            }
            .overlay(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// The Glass Capsules/Floating Text preview-card picker for the row's
/// overall appearance, same card style as the metric pickers below.
struct MiniWidgetAppearanceStyleCard: View {
    let style: MiniWidgetAppearanceStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    MiniWidgetPreviewCardBackground(isSelected: isSelected)
                    preview
                }
                .frame(width: 96, height: 64)
                Text(style.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preview: some View {
        switch style {
        case .glassCapsules:
            HStack(spacing: 3) {
                Image(systemName: "battery.75")
                Text("82%")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
        case .floatingText:
            HStack(spacing: 3) {
                Image(systemName: "battery.75")
                Text("82%")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .opacity(0.75)
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
        }
    }
}

/// One row in the mini-widgets toggle list: a colored icon badge (same shape
/// as SettingsView's SettingsSidebarIcon) + label + Toggle.
struct LockScreenMiniWidgetToggleRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let key: Defaults.Key<Bool>

    var body: some View {
        Defaults.Toggle(key: key) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(1.0), tint.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
                            .blendMode(.plusLighter)
                    }
                    .shadow(color: tint.opacity(0.35), radius: 2, x: 0, y: 1)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text(title)
            }
        }
    }
}

/// The Percentage/Time Remaining preview-card picker for the battery
/// mini-widget, same card style as MiniWidgetWeatherMetricCard below.
struct MiniWidgetBatteryMetricCard: View {
    let metric: MiniWidgetBatteryMetric
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    MiniWidgetPreviewCardBackground(isSelected: isSelected)
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .foregroundStyle(.orange)
                        Text(sampleValue)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: 96, height: 64)
                Text(metric.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch metric {
        case .percentage: return "battery.75"
        case .timeRemaining: return "clock.fill"
        }
    }

    private var sampleValue: String {
        switch metric {
        case .percentage: return "82%"
        case .timeRemaining: return "3h 45m"
        }
    }
}

/// The Conditions/Sun/Precipitation segmented preview-card picker for the
/// weather mini-widget, matching the reference lock-screen settings' card
/// style: rounded-rect preview, accent-colored border on the selected card.
struct MiniWidgetWeatherMetricCard: View {
    let metric: MiniWidgetWeatherMetric
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    MiniWidgetPreviewCardBackground(isSelected: isSelected)
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .foregroundStyle(iconColor)
                        Text(sampleValue)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: 96, height: 64)
                Text(metric.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch metric {
        case .conditions: return "sun.max.fill"
        case .sun: return "sunrise.fill"
        case .precipitation: return "umbrella.fill"
        }
    }

    private var iconColor: Color {
        switch metric {
        case .conditions: return .orange
        case .sun: return .yellow
        case .precipitation: return .blue
        }
    }

    private var sampleValue: String {
        switch metric {
        case .conditions: return "24°"
        case .sun: return "6 am"
        case .precipitation: return "12%"
        }
    }
}

struct LockScreenMiniWidgetsSection: View {
    @Default(.lockScreenMiniWidgetsEnabled) private var miniWidgetsEnabled
    @Default(.lockScreenMiniWidgetAppearance) private var appearance
    @Default(.lockScreenBatteryMiniWidget) private var batteryEnabled
    @Default(.lockScreenMiniWidgetBatteryMetric) private var batteryMetric
    @Default(.lockScreenWeatherMiniWidget) private var weatherEnabled
    @Default(.lockScreenMiniWidgetWeatherMetric) private var weatherMetric

    var body: some View {
        Text("Mini-Widgets")
            .font(.system(size: 15, weight: .bold))
            .padding(.leading, 4)

        Section {
            Defaults.Toggle(key: .lockScreenMiniWidgetsEnabled) {
                Text("Show mini-widgets on lock screen")
            }
            .settingsHighlight(id: "LockScreen-Show mini-widgets")
        }

        Section {
            HStack(spacing: 12) {
                ForEach(MiniWidgetAppearanceStyle.allCases) { style in
                    MiniWidgetAppearanceStyleCard(
                        style: style,
                        isSelected: appearance == style,
                        action: { appearance = style }
                    )
                }
            }
            .padding(.vertical, 4)
            .settingsHighlight(id: "LockScreen-Mini-widget appearance")
        }
        .disabled(!miniWidgetsEnabled)
        .opacity(miniWidgetsEnabled ? 1 : 0.4)

        Section {
            LockScreenMiniWidgetToggleRow(
                title: "Battery",
                systemImage: "battery.100.bolt",
                tint: .orange,
                key: .lockScreenBatteryMiniWidget
            )
            .settingsHighlight(id: "LockScreen-Battery mini-widget")

            if batteryEnabled {
                HStack(spacing: 12) {
                    ForEach(MiniWidgetBatteryMetric.allCases) { metric in
                        MiniWidgetBatteryMetricCard(
                            metric: metric,
                            isSelected: batteryMetric == metric,
                            action: { batteryMetric = metric }
                        )
                    }
                }
                .padding(.vertical, 4)
                .settingsHighlight(id: "LockScreen-Battery metric")
            }

            LockScreenMiniWidgetToggleRow(
                title: "Connectivity",
                systemImage: "headphones",
                tint: .green,
                key: .lockScreenConnectivityMiniWidget
            )
            .settingsHighlight(id: "LockScreen-Connectivity mini-widget")

            LockScreenMiniWidgetToggleRow(
                title: "Focus",
                systemImage: "moon.fill",
                tint: .indigo,
                key: .lockScreenFocusMiniWidget
            )
            .settingsHighlight(id: "LockScreen-Focus mini-widget")

            LockScreenMiniWidgetToggleRow(
                title: "Calendar",
                systemImage: "calendar",
                tint: .red,
                key: .lockScreenCalendarMiniWidget
            )
            .settingsHighlight(id: "LockScreen-Calendar mini-widget")

            Defaults.Toggle(key: .lockScreenWeatherMiniWidget) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(1.0), Color.blue.opacity(0.65)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "cloud.sun.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    Text("Weather")
                    Image(systemName: "location.fill")
                        .modifier(HoverTooltip(text: "Requires location permissions"))
                }
            }
            .settingsHighlight(id: "LockScreen-Weather mini-widget")

            if weatherEnabled {
                HStack(spacing: 12) {
                    ForEach(MiniWidgetWeatherMetric.allCases) { metric in
                        MiniWidgetWeatherMetricCard(
                            metric: metric,
                            isSelected: weatherMetric == metric,
                            action: { weatherMetric = metric }
                        )
                    }
                }
                .padding(.vertical, 4)
                .settingsHighlight(id: "LockScreen-Weather metric")
            }
        } footer: {
            Text("Shows a row of small widgets under the clock while your Mac is locked.")
        }
        .disabled(!miniWidgetsEnabled)
        .opacity(miniWidgetsEnabled ? 1 : 0.4)
    }
}
