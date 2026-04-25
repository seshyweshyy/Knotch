//
//  SettingsView.swift
//  Knotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import AVFoundation
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
import SwiftUI
import SwiftUIIntrospect

// MARK: - Settings Tab Model

private struct SettingsTabItem: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let group: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func highlightID(for setting: String) -> String {
        "\(id)-\(setting)"
    }
}

private let knotchTabs: [SettingsTabItem] = [
    // Core — no section header
    SettingsTabItem(id: "General", title: "General", systemImage: "gear", tint: .blue, group: ""),
    SettingsTabItem(id: "Appearance", title: "Appearance", systemImage: "eye", tint: .purple, group: ""),
    // Content
    SettingsTabItem(id: "Widgets", title: "Widgets", systemImage: "rectangle.3.group", tint: .indigo, group: "Content"),
    SettingsTabItem(id: "Media", title: "Media", systemImage: "play.laptopcomputer", tint: .green, group: "Content"),
    SettingsTabItem(id: "Calendar", title: "Calendar", systemImage: "calendar", tint: .cyan, group: "Content"),
    SettingsTabItem(id: "Shelf", title: "Shelf", systemImage: "books.vertical", tint: .brown, group: "Content"),
    // System
    SettingsTabItem(id: "HUD", title: "HUDs", systemImage: "dial.medium.fill", tint: .black, group: "System"),
    SettingsTabItem(id: "Battery", title: "Battery", systemImage: "battery.100.bolt", tint: Color(red: 0.2, green: 0.78, blue: 0.35), group: "System"),
    SettingsTabItem(id: "Bluetooth", title: "Bluetooth", systemImage: "airpodspro", tint: .blue, group: "System"),
    // More
    SettingsTabItem(id: "Shortcuts", title: "Shortcuts", systemImage: "keyboard", tint: .orange, group: "More"),
    SettingsTabItem(id: "Advanced", title: "Advanced", systemImage: "gearshape.2", tint: .gray, group: "More"),
    SettingsTabItem(id: "About", title: "About", systemImage: "info.circle", tint: Color.secondary, group: "More"),
]

// MARK: - Sidebar Icon

private struct SettingsSidebarIcon: View {
    let tab: SettingsTabItem

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tab.tint.opacity(1.0), tab.tint.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 26, height: 26)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
                    .blendMode(.plusLighter)
            }
            .shadow(color: tab.tint.opacity(0.35), radius: 2, x: 0, y: 1)
            .overlay {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

private struct SettingsDetailHeader: View {
    let tab: SettingsTabItem

    var body: some View {
        HStack(spacing: 10) {
            SettingsSidebarIcon(tab: tab)
                .scaleEffect(1.15)
            Text(tab.title)
                .font(.title2)
                .fontWeight(.bold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Search Entry Model

private struct SettingsSearchEntry: Identifiable {
    let tabID: String
    let title: String
    let keywords: [String]
    let highlightID: String?
    var id: String { "\(tabID)-\(title)" }
}

// MARK: - Sidebar Search Bar

private struct SettingsSidebarSearchBar: View {
    @Binding var text: String
    let suggestions: [SettingsSearchEntry]
    let allTabs: [SettingsTabItem]
    let onSuggestionSelected: (SettingsSearchEntry) -> Void

    @FocusState private var isFocused: Bool
    @State private var hoveredID: String?

    private var showSuggestions: Bool {
        isFocused && !text.trimmingCharacters(in: .whitespaces).isEmpty && !suggestions.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .medium))

                TextField("Search Settings", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit {
                        if let first = suggestions.first {
                            onSuggestionSelected(first)
                            isFocused = false
                        }
                    }

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .shadow(color: .black.opacity(0.08), radius: 1.5, x: 0, y: 1)
            )
            .animation(.easeInOut(duration: 0.15), value: text.isEmpty)

            if showSuggestions {
                VStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        let tab = allTabs.first { $0.id == suggestion.tabID }
                        Button {
                            onSuggestionSelected(suggestion)
                            isFocused = false
                        } label: {
                            HStack(spacing: 10) {
                                if let tab {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [tab.tint.opacity(1.0), tab.tint.opacity(0.65)],
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
                                        .shadow(color: tab.tint.opacity(0.3), radius: 2, x: 0, y: 1)
                                        .overlay {
                                            Image(systemName: tab.systemImage)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.white)
                                        }
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(tab?.title ?? suggestion.tabID)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(hoveredID == suggestion.id ? Color.white.opacity(0.08) : Color.clear)
                                    .padding(.horizontal, 4)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredID = hovering ? suggestion.id : nil
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showSuggestions)
    }
}

// MARK: - Highlight Coordinator

final class SettingsHighlightCoordinator: ObservableObject {
    struct ScrollRequest: Identifiable, Equatable {
        let id: String        // the highlightID to scroll to
        let tabID: String     // which tab owns it
    }

    @Published fileprivate var pendingScrollRequest: ScrollRequest?
    @Published private(set) var activeHighlightID: String?
    private var clearTask: DispatchWorkItem?

    fileprivate func focus(on entry: SettingsSearchEntry) {
        guard let hid = entry.highlightID else { return }
        pendingScrollRequest = ScrollRequest(id: hid, tabID: entry.tabID)
        activateHighlight(id: hid)
    }

    func consumeScrollRequest(_ request: ScrollRequest) {
        guard pendingScrollRequest?.id == request.id else { return }
        pendingScrollRequest = nil
    }

    private func activateHighlight(id: String) {
        activeHighlightID = id
        clearTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.activeHighlightID == id else { return }
            withAnimation { self?.activeHighlightID = nil }
        }
        clearTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}

private struct SettingsForm<Content: View>: View {
    let tabID: String
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var highlightCoordinator: SettingsHighlightCoordinator

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .onReceive(highlightCoordinator.$pendingScrollRequest.compactMap { request -> SettingsHighlightCoordinator.ScrollRequest? in
                    guard let request, request.tabID == tabID else { return nil }
                    return request
                }) { request in
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(request.id, anchor: .center)
                    }
                    highlightCoordinator.consumeScrollRequest(request)
                }
        }
    }
}

// MARK: - Highlight View Modifier

private struct SettingsHighlightModifier: ViewModifier {
    let id: String
    @EnvironmentObject private var coordinator: SettingsHighlightCoordinator
    @State private var pulse = false

    private var isActive: Bool { coordinator.activeHighlightID == id }

    func body(content: Content) -> some View {
        content
            .id(id)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(isActive ? (pulse ? 0.9 : 0.35) : 0), lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(isActive ? 0.07 : 0))
                    )
                    .shadow(color: Color.accentColor.opacity(isActive ? 0.2 : 0), radius: pulse ? 6 : 2)
                    .padding(-6)
                    .animation(
                        isActive ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true) : .default,
                        value: pulse
                    )
            )
            .onChange(of: isActive) { _, active in pulse = active }
            .onAppear { if isActive { pulse = true } }
    }
}

extension View {
    func settingsHighlight(id: String) -> some View {
        modifier(SettingsHighlightModifier(id: id))
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @State private var selectedTab = "General"
    @State private var accentColorUpdateTrigger = UUID()
    @State private var searchText = ""
    @StateObject private var highlightCoordinator = SettingsHighlightCoordinator()

    let updaterController: SPUStandardUpdaterController?

    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
    }

    // MARK: - Search Index

    private var searchIndex: [SettingsSearchEntry] {
        [
            // General
            SettingsSearchEntry(tabID: "General", title: "Show menu bar icon", keywords: ["menu bar", "menubar", "status bar"], highlightID: "General-Show menu bar icon"),
            SettingsSearchEntry(tabID: "General", title: "Launch at login", keywords: ["startup", "autostart"], highlightID: "General-Launch at login"),
            SettingsSearchEntry(tabID: "General", title: "Show on all displays", keywords: ["multi-display", "monitor"], highlightID: "General-Show on all displays"),
            SettingsSearchEntry(tabID: "General", title: "Preferred display", keywords: ["external", "screen", "display picker"], highlightID: "General-External display support"),
            SettingsSearchEntry(tabID: "General", title: "Automatically switch displays", keywords: ["auto switch", "display"], highlightID: "General-Automatically switch displays"),
            SettingsSearchEntry(tabID: "General", title: "Notch height on notch displays", keywords: ["notch height", "sizing"], highlightID: "General-Notch height on notch displays"),
            SettingsSearchEntry(tabID: "General", title: "Notch height on non-notch displays", keywords: ["non-notch", "height", "sizing"], highlightID: "General-Notch height on non-notch displays"),
            SettingsSearchEntry(tabID: "General", title: "Open notch on hover", keywords: ["hover", "hide", "notch"], highlightID: "General-Hide until hover"),
            SettingsSearchEntry(tabID: "General", title: "Enable haptic feedback", keywords: ["haptic", "vibration"], highlightID: "General-Enable haptic feedback"),
            SettingsSearchEntry(tabID: "General", title: "Remember last tab", keywords: ["tab", "remember", "restore"], highlightID: "General-Remember last tab"),
            SettingsSearchEntry(tabID: "General", title: "Hover delay", keywords: ["hover", "delay", "timing"], highlightID: "General-Hover delay"),
            SettingsSearchEntry(tabID: "General", title: "Enable gestures", keywords: ["gesture", "swipe", "trackpad"], highlightID: "General-Enable gestures"),
            SettingsSearchEntry(tabID: "General", title: "Close gesture", keywords: ["close", "gesture", "swipe"], highlightID: "General-Close gesture"),
            SettingsSearchEntry(tabID: "General", title: "Swipe to cycle views", keywords: ["swipe", "cycle", "views"], highlightID: "General-Swipe to cycle views"),
            SettingsSearchEntry(tabID: "General", title: "Gesture sensitivity", keywords: ["gesture", "sensitivity", "speed"], highlightID: "General-Gesture sensitivity"),
            // Appearance
            SettingsSearchEntry(tabID: "Appearance", title: "Always show tabs", keywords: ["tabs", "always visible"], highlightID: "Appearance-Always show tabs"),
            SettingsSearchEntry(tabID: "Appearance", title: "Show settings icon in notch", keywords: ["settings", "gear", "icon", "notch"], highlightID: "Appearance-Show settings icon in notch"),
            SettingsSearchEntry(tabID: "Appearance", title: "Colored spectrogram", keywords: ["color", "spectrogram", "music"], highlightID: "Media-Colored spectrograms"),
            SettingsSearchEntry(tabID: "Appearance", title: "Player tinting", keywords: ["tint", "player", "color"], highlightID: "Appearance-Player tinting"),
            SettingsSearchEntry(tabID: "Appearance", title: "Enable blur effect behind album art", keywords: ["blur", "glass", "album art"], highlightID: "Appearance-Enable blur effect"),
            SettingsSearchEntry(tabID: "Appearance", title: "Slider color", keywords: ["slider", "color", "accent"], highlightID: "Appearance-Slider color"),
            SettingsSearchEntry(tabID: "Appearance", title: "Enable mirror", keywords: ["mirror", "camera", "reflection"], highlightID: "Advanced-Enable Dynamic mirror"),
            SettingsSearchEntry(tabID: "Appearance", title: "Mirror shape", keywords: ["mirror", "shape", "circle", "square"], highlightID: "Advanced-Mirror shape"),
            // Widgets
            SettingsSearchEntry(tabID: "Widgets", title: "Music player widget", keywords: ["music", "widget", "player"], highlightID: "Widgets-Toggle expanded notch widgets"),
            SettingsSearchEntry(tabID: "Widgets", title: "Calendar widget", keywords: ["calendar", "widget"], highlightID: "Widgets-Show calendar widget"),
            SettingsSearchEntry(tabID: "Widgets", title: "Mirror widget", keywords: ["mirror", "camera", "widget"], highlightID: "Widgets-Mirror widget"),
            // Media
            SettingsSearchEntry(tabID: "Media", title: "Music source", keywords: ["music", "source", "spotify", "youtube"], highlightID: "Media-Music source"),
            SettingsSearchEntry(tabID: "Media", title: "Show music live activity", keywords: ["music", "live activity", "player"], highlightID: "Media-Enable media player"),
            SettingsSearchEntry(tabID: "Media", title: "Show sneak peek on playback changes", keywords: ["sneak peek", "playback"], highlightID: "Media-Show playback controls"),
            SettingsSearchEntry(tabID: "Media", title: "Sneak peek style", keywords: ["sneak peek", "style"], highlightID: "Media-Sneak peek style"),
            SettingsSearchEntry(tabID: "Media", title: "Media inactivity timeout", keywords: ["timeout", "inactivity", "media"], highlightID: "Media-Media inactivity timeout"),
            SettingsSearchEntry(tabID: "Media", title: "Full screen behavior", keywords: ["full screen", "hide", "behavior"], highlightID: "Media-Full screen behavior"),
            SettingsSearchEntry(tabID: "Media", title: "Show music widget on lock screen", keywords: ["lock screen", "music", "widget"], highlightID: "Media-Show album art"),
            SettingsSearchEntry(tabID: "Media", title: "Enable expanded album art", keywords: ["expanded", "album", "art", "lock screen", "background"], highlightID: "Media-Expanded album art"),
            SettingsSearchEntry(tabID: "Media", title: "Show lyrics below artist name", keywords: ["lyrics", "artist"], highlightID: "Media-Show lyrics"),
            // Calendar
            SettingsSearchEntry(tabID: "Calendar", title: "Show calendar", keywords: ["calendar", "notch"], highlightID: "Calendar-Show calendar in notch"),
            SettingsSearchEntry(tabID: "Calendar", title: "Hide completed reminders", keywords: ["reminders", "completed", "hide"], highlightID: "Calendar-Hide completed reminders"),
            SettingsSearchEntry(tabID: "Calendar", title: "Hide all-day events", keywords: ["all-day", "events", "hide"], highlightID: "Calendar-Hide all-day events"),
            SettingsSearchEntry(tabID: "Calendar", title: "Auto-scroll to next event", keywords: ["scroll", "event", "next"], highlightID: "Calendar-Calendar event count"),
            SettingsSearchEntry(tabID: "Calendar", title: "Always show full event titles", keywords: ["event", "title", "full"], highlightID: "Calendar-Always show full event titles"),
            // HUD
            SettingsSearchEntry(tabID: "HUD", title: "Replace system HUD", keywords: ["replace", "system", "hud", "volume", "brightness"], highlightID: "HUD-Replace system HUD"),
            SettingsSearchEntry(tabID: "HUD", title: "Option key behaviour", keywords: ["option", "key", "hud"], highlightID: "HUD-Option key behaviour"),
            SettingsSearchEntry(tabID: "HUD", title: "Progress bar style", keywords: ["gradient", "hierarchical", "progress"], highlightID: "HUD-Progress bar style"),
            SettingsSearchEntry(tabID: "HUD", title: "Enable glowing effect", keywords: ["glow", "shadow", "hud"], highlightID: "HUD-Enable glowing effect"),
            SettingsSearchEntry(tabID: "HUD", title: "Tint progress bar with accent color", keywords: ["tint", "accent", "progress"], highlightID: "HUD-Enable volume HUD"),
            SettingsSearchEntry(tabID: "HUD", title: "Show HUD in open notch", keywords: ["open notch", "hud", "show"], highlightID: "HUD-Show HUD in open notch"),
            SettingsSearchEntry(tabID: "HUD", title: "HUD style", keywords: ["hud", "inline", "default", "style"], highlightID: "HUD-HUD style"),
            // Bluetooth
            SettingsSearchEntry(tabID: "Bluetooth", title: "Show Bluetooth device connections", keywords: ["bluetooth", "device", "connection", "hud"], highlightID: "Bluetooth-Show Bluetooth device connections"),
            SettingsSearchEntry(tabID: "Bluetooth", title: "HUD icon style", keywords: ["bluetooth", "icon", "3d", "symbol", "style"], highlightID: "Bluetooth-HUD icon style"),
            // Battery
            SettingsSearchEntry(tabID: "Battery", title: "Show battery indicator", keywords: ["battery", "indicator"], highlightID: "Battery-Show battery indicator"),
            SettingsSearchEntry(tabID: "Battery", title: "Show power status notifications", keywords: ["power", "notification", "battery"], highlightID: "Battery-Show power status notifications"),
            SettingsSearchEntry(tabID: "Battery", title: "Show battery percentage", keywords: ["battery", "percentage"], highlightID: "Battery-Show battery percentage"),
            SettingsSearchEntry(tabID: "Battery", title: "Show power status icons", keywords: ["power", "icons", "battery"], highlightID: "Battery-Show power status icons"),
            // Shelf
            SettingsSearchEntry(tabID: "Shelf", title: "Enable shelf", keywords: ["shelf", "drop"], highlightID: "Shelf-Enable shelf"),
            SettingsSearchEntry(tabID: "Shelf", title: "Open shelf by default if items are present", keywords: ["shelf", "default", "open"], highlightID: "Shelf-Open shelf by default"),
            SettingsSearchEntry(tabID: "Shelf", title: "Expanded drag detection area", keywords: ["drag", "detection", "shelf"], highlightID: "Shelf-Expanded drag detection"),
            SettingsSearchEntry(tabID: "Shelf", title: "Copy items on drag", keywords: ["copy", "drag", "shelf"], highlightID: "Shelf-Copy items on drag"),
            SettingsSearchEntry(tabID: "Shelf", title: "Remove from shelf after dragging", keywords: ["remove", "drag", "shelf"], highlightID: "Shelf-Remove after dragging"),
            SettingsSearchEntry(tabID: "Shelf", title: "Quick Share Service", keywords: ["share", "airdrop", "localsend", "shelf"], highlightID: "Shelf-Shelf activation gesture"),
            // Shortcuts
            SettingsSearchEntry(tabID: "Shortcuts", title: "Toggle Sneak Peek", keywords: ["sneak peek", "shortcut"], highlightID: "Shortcuts-Toggle Sneak Peek"),
            SettingsSearchEntry(tabID: "Shortcuts", title: "Toggle notch open", keywords: ["open", "shortcut", "keyboard"], highlightID: "Shortcuts-Toggle notch open"),
            // Advanced
            SettingsSearchEntry(tabID: "Advanced", title: "Accent color", keywords: ["accent", "color", "tint", "custom"], highlightID: "Advanced-Accent color"),
            SettingsSearchEntry(tabID: "Advanced", title: "Enable window shadow", keywords: ["shadow", "window"], highlightID: "Appearance-Enable window shadow"),
            SettingsSearchEntry(tabID: "Advanced", title: "Corner radius scaling", keywords: ["corner", "radius", "scaling"], highlightID: "Appearance-Corner radius scaling"),
            //SettingsSearchEntry(tabID: "Advanced", title: "Progressive edge blur when notch is open", keywords: ["edge", "blur", "progressive"], highlightID: "Appearance-Progressive edge blur"),
            SettingsSearchEntry(tabID: "Advanced", title: "Extend hover area", keywords: ["hover", "area", "extend"], highlightID: "Advanced-Extend hover area"),
            SettingsSearchEntry(tabID: "Advanced", title: "Hide title bar", keywords: ["title bar", "hide"], highlightID: "Advanced-Hide title bar"),
            SettingsSearchEntry(tabID: "Advanced", title: "Show notch on lock screen", keywords: ["lock screen", "notch"], highlightID: "Advanced-Show on lock screen"),
            SettingsSearchEntry(tabID: "Advanced", title: "Hide from screen recording", keywords: ["screen recording", "privacy", "hide"], highlightID: "Advanced-Hide from screen recording"),
            SettingsSearchEntry(tabID: "Advanced", title: "Custom visualizers", keywords: ["lottie", "visualizer", "custom"], highlightID: "Advanced-Custom visualizers"),
        ]
    }

    private var searchSuggestions: [SettingsSearchEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return Array(
            searchIndex.filter { entry in
                entry.title.localizedCaseInsensitiveContains(trimmed) ||
                entry.keywords.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            }
            .prefix(8)
        )
    }

    private var filteredTabs: [SettingsTabItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return knotchTabs }
        let matchingTabIDs = Set(searchSuggestions.map(\.tabID))
        return knotchTabs.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || matchingTabIDs.contains($0.id)
        }
    }

    private var groupedTabs: [(header: String?, tabs: [SettingsTabItem])] {
        var result: [(header: String?, tabs: [SettingsTabItem])] = []
        var seen: Set<String> = []
        var order: [String] = []
        for tab in filteredTabs {
            if !seen.contains(tab.group) {
                seen.insert(tab.group)
                order.append(tab.group)
            }
        }
        for group in order {
            let tabs = filteredTabs.filter { $0.group == group }
            result.append((header: group.isEmpty ? nil : group, tabs: tabs))
        }
        return result
    }

    private func handleSuggestionSelected(_ suggestion: SettingsSearchEntry) {
        selectedTab = suggestion.tabID
        searchText = ""
        highlightCoordinator.focus(on: suggestion)
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar
            VStack(spacing: 0) {
                SettingsSidebarSearchBar(
                    text: $searchText,
                    suggestions: searchSuggestions,
                    allTabs: knotchTabs,
                    onSuggestionSelected: handleSuggestionSelected
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 12)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groupedTabs, id: \.header) { section in
                            if let header = section.header {
                                Text(header)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 2)
                            }
                            ForEach(section.tabs) { tab in
                                Button {
                                    selectedTab = tab.id
                                } label: {
                                    HStack(spacing: 10) {
                                        SettingsSidebarIcon(tab: tab)
                                        Text(tab.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(selectedTab == tab.id ? Color.effectiveAccent : Color.clear)
                                            .padding(.horizontal, 4)
                                    )
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(width: 210)
            .padding(.vertical, 10)

            Divider()

            // MARK: Detail
            VStack(spacing: 0) {
                if let tab = knotchTabs.first(where: { $0.id == selectedTab }) {
                    SettingsDetailHeader(tab: tab)
                }
                Group {
                    switch selectedTab {
                    case "General":
                        SettingsForm(tabID: "General") { GeneralSettings() }
                    case "Appearance":
                        SettingsForm(tabID: "Appearance") { Appearance() }
                    case "Widgets":
                        SettingsForm(tabID: "Widgets") { Widgets() }
                    case "Media":
                        SettingsForm(tabID: "Media") { Media() }
                    case "Calendar":
                        SettingsForm(tabID: "Calendar") { CalendarSettings() }
                    case "HUD":
                        SettingsForm(tabID: "HUD") { HUD() }
                    case "Battery":
                        SettingsForm(tabID: "Battery") { Charge() }
                    case "Bluetooth":
                        SettingsForm(tabID: "Bluetooth") { BluetoothSettings() }
                    case "Shelf":
                        SettingsForm(tabID: "Shelf") { Shelf() }
                    case "Shortcuts":
                        SettingsForm(tabID: "Shortcuts") { Shortcuts() }
                    case "Advanced":
                        SettingsForm(tabID: "Advanced") { Advanced() }
                    case "About":
                        SettingsForm(tabID: "About") {
                            if let controller = updaterController {
                                About(updaterController: controller)
                            } else {
                                About(updaterController: SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil))
                            }
                        }
                    default:
                        SettingsForm(tabID: "General") { GeneralSettings() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(highlightCoordinator)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 620)
        .background(Color.clear)
        .formStyle(.grouped)
        .tint(.effectiveAccent)
        .id(accentColorUpdateTrigger)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccentColorChanged"))) { _ in
            accentColorUpdateTrigger = UUID()
        }
    }
}


// MARK: - GeneralSettings

struct GeneralSettings: View {
    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var coordinator = KnotchViewCoordinator.shared

    @Default(.mirrorShape) var mirrorShape
    @Default(.showEmojis) var showEmojis
    @Default(.gestureSensitivity) var gestureSensitivity
    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.enableGestures) var enableGestures
    @Default(.openNotchOnHover) var openNotchOnHover

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { Defaults[.menubarIcon] },
                    set: { Defaults[.menubarIcon] = $0 }
                )) {
                    Text("Show menu bar icon")
                }
                .tint(.effectiveAccent)
                .settingsHighlight(id: "General-Show menu bar icon")
                LaunchAtLogin.Toggle("Launch at login")
                    .settingsHighlight(id: "General-Launch at login")
                Defaults.Toggle(key: .showOnAllDisplays) {
                    Text("Show on all displays")
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                }
                .settingsHighlight(id: "General-Show on all displays")
                Picker("Preferred display", selection: $coordinator.preferredScreenUUID) {
                    ForEach(screens, id: \.uuid) { screen in
                        Text(screen.name).tag(screen.uuid as String?)
                    }
                }
                .onChange(of: NSScreen.screens) {
                    screens = NSScreen.screens.compactMap { screen in
                        guard let uuid = screen.displayUUID else { return nil }
                        return (uuid, screen.localizedName)
                    }
                }
                .disabled(showOnAllDisplays)
                .settingsHighlight(id: "General-External display support")
                Defaults.Toggle(key: .automaticallySwitchDisplay) {
                    Text("Automatically switch displays")
                }
                .onChange(of: automaticallySwitchDisplay) {
                    NotificationCenter.default.post(name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
                }
                .disabled(showOnAllDisplays)
                .settingsHighlight(id: "General-Automatically switch displays")
            } header: {
                Text("System features")
            }

            Section {
                Picker(selection: $notchHeightMode, label: Text("Notch height on notch displays")) {
                    Text("Match real notch height").tag(WindowHeightMode.matchRealNotchSize)
                    Text("Match menu bar height").tag(WindowHeightMode.matchMenuBar)
                    Text("Custom height").tag(WindowHeightMode.custom)
                }
                .onChange(of: notchHeightMode) {
                    switch notchHeightMode {
                    case .matchRealNotchSize: notchHeight = 38
                    case .matchMenuBar: notchHeight = 44
                    case .custom: notchHeight = 38
                    }
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
                .settingsHighlight(id: "General-Notch height on notch displays")
                if notchHeightMode == .custom {
                    Slider(value: $notchHeight, in: 15...45, step: 1) {
                        Text("Custom notch size - \(notchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: notchHeight) {
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
                Picker("Notch height on non-notch displays", selection: $nonNotchHeightMode) {
                    Text("Match menubar height").tag(WindowHeightMode.matchMenuBar)
                    Text("Match real notch height").tag(WindowHeightMode.matchRealNotchSize)
                    Text("Custom height").tag(WindowHeightMode.custom)
                }
                .onChange(of: nonNotchHeightMode) {
                    switch nonNotchHeightMode {
                    case .matchMenuBar: nonNotchHeight = 24
                    case .matchRealNotchSize: nonNotchHeight = 32
                    case .custom: nonNotchHeight = 32
                    }
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
                .settingsHighlight(id: "General-Notch height on non-notch displays")
                if nonNotchHeightMode == .custom {
                    Slider(value: $nonNotchHeight, in: 0...40, step: 1) {
                        Text("Custom notch size - \(nonNotchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: nonNotchHeight) {
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            } header: {
                Text("Notch sizing")
            }

            NotchBehaviour()
            gestureControls()
        }
        .toolbar {
            Button("Quit app") {
                NSApp.terminate(self)
            }
            .controlSize(.extraLarge)
        }
        .accentColor(.effectiveAccent)
        .onChange(of: openNotchOnHover) {
            if !openNotchOnHover {
                enableGestures = true
            }
        }
    }

    @ViewBuilder
    func gestureControls() -> some View {
        Section {
            Defaults.Toggle(key: .enableGestures) {
                Text("Enable gestures")
            }
            .disabled(!openNotchOnHover)
            .settingsHighlight(id: "General-Enable gestures")
            if enableGestures {
                Toggle("Change media with horizontal gestures", isOn: .constant(false))
                    .disabled(true)
                Defaults.Toggle(key: .closeGestureEnabled) {
                    Text("Close gesture")
                }
                .settingsHighlight(id: "General-Close gesture")
                Defaults.Toggle(key: .swipeToCycleViews) {
                    Text("Swipe to cycle views")
                }
                .settingsHighlight(id: "General-Swipe to cycle views")
                Slider(value: $gestureSensitivity, in: 100...300, step: 100) {
                    HStack {
                        Text("Gesture sensitivity")
                        Spacer()
                        Text(
                            Defaults[.gestureSensitivity] == 100 ? "High"
                            : Defaults[.gestureSensitivity] == 200 ? "Medium" : "Low"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .settingsHighlight(id: "General-Gesture sensitivity")
            }
        } header: {
            HStack {
                Text("Gesture control")
                customBadge(text: "Beta")
            }
        } footer: {
            Text(
                "Two-finger swipe up on notch to close, two-finger swipe down on notch to open when 'Open notch on hover' option is disabled or to cycle through activities when notch is expanded"
            )
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
    }

    @ViewBuilder
    func NotchBehaviour() -> some View {
        Section {
            Defaults.Toggle(key: .openNotchOnHover) {
                Text("Open notch on hover")
            }
            .settingsHighlight(id: "General-Hide until hover")
            Defaults.Toggle(key: .enableHaptics) {
                Text("Enable haptic feedback")
            }
            .settingsHighlight(id: "General-Enable haptic feedback")
            Toggle("Remember last tab", isOn: $coordinator.openLastTabByDefault)
                .settingsHighlight(id: "General-Remember last tab")
            if openNotchOnHover {
                Slider(value: $minimumHoverDuration, in: 0...1, step: 0.1) {
                    HStack {
                        Text("Hover delay")
                        Spacer()
                        Text("\(minimumHoverDuration, specifier: "%.1f")s")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: minimumHoverDuration) {
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
                .settingsHighlight(id: "General-Hover delay")
            }
        } header: {
            Text("Notch behavior")
        }
    }
}

// MARK: - Charge

struct Charge: View {
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showBatteryIndicator) {
                    Text("Show battery indicator")
                }
                .settingsHighlight(id: "Battery-Show battery indicator")
                Defaults.Toggle(key: .showPowerStatusNotifications) {
                    Text("Show power status notifications")
                }
                .settingsHighlight(id: "Battery-Show power status notifications")
            } header: {
                Text("General")
            }
            Section {
                Defaults.Toggle(key: .showBatteryPercentage) {
                    Text("Show battery percentage")
                }
                .settingsHighlight(id: "Battery-Show battery percentage")
                Defaults.Toggle(key: .showPowerStatusIcons) {
                    Text("Show power status icons")
                }
                .settingsHighlight(id: "Battery-Show power status icons")
            } header: {
                Text("Battery Information")
            }
        }
        .onAppear {
            Task { @MainActor in
                await XPCHelperClient.shared.isAccessibilityAuthorized()
            }
        }
        .accentColor(.effectiveAccent)
    }
}

// MARK: - Bluetooth

struct BluetoothSettings: View {
    @Default(.showBluetoothDeviceConnections) var showBluetoothDeviceConnections
    @Default(.bluetoothHUDIconStyle) var bluetoothHUDIconStyle

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showBluetoothDeviceConnections) {
                    Text("Show Bluetooth device connections")
                }
                .settingsHighlight(id: "Bluetooth-Show Bluetooth device connections")
                VStack(alignment: .leading, spacing: 8) {
                    Text("HUD icon style")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Spacer()
                        ForEach(BluetoothHUDIconStyle.allCases, id: \.self) { style in
                            Button {
                                bluetoothHUDIconStyle = style
                            } label: {
                                VStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                                        .frame(width: 80, height: 80)
                                        .overlay {
                                            Group {
                                                if style == .threeDimensional,
                                                   let url = Bundle.main.url(forResource: "airpodsPro", withExtension: "mov") {
                                                    LoopingVideoView(url: url)
                                                        .frame(width: 45, height: 45)
                                                        .allowsHitTesting(false)
                                                } else if style == .threeDimensional {
                                                    Image(systemName: "airpodspro")
                                                        .font(.system(size: 25, weight: .medium))
                                                        .symbolRenderingMode(.hierarchical)
                                                        .foregroundStyle(.white)
                                                } else {
                                                    Image(systemName: "airpodspro")
                                                        .font(.system(size: 25, weight: .medium))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                        }
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(
                                                    bluetoothHUDIconStyle == style ? Color.accentColor : Color.clear,
                                                    lineWidth: 2.5
                                                )
                                        }
                                    Text(style.rawValue)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!showBluetoothDeviceConnections)
                        }
                        Spacer()
                    }
                }
                .settingsHighlight(id: "Bluetooth-HUD icon style")
            } header: {
                Text("Connection HUD")
            }
        }
        .accentColor(.effectiveAccent)
    }
}

struct LoopingVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in player.seek(to: .zero); player.play() }
        player.play()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}


// MARK: - HUD

struct HUD: View {
    @EnvironmentObject var vm: KnotchViewModel
    @Default(.inlineHUD) var inlineHUD
    @Default(.enableGradient) var enableGradient
    @Default(.optionKeyAction) var optionKeyAction
    @Default(.hudReplacement) var hudReplacement
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @State private var accessibilityAuthorized = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replace system HUD")
                            .font(.headline)
                        Text("Replaces the standard macOS volume, display brightness, and keyboard brightness HUDs with a custom design.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 40)
                    Defaults.Toggle("", key: .hudReplacement)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.large)
                        .disabled(!accessibilityAuthorized)
                }
                .settingsHighlight(id: "HUD-Replace system HUD")
                if !accessibilityAuthorized {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accessibility access is required to replace the system HUD.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Request Accessibility") {
                                XPCHelperClient.shared.requestAccessibilityAuthorization()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Section {
                Picker("Option key behaviour", selection: $optionKeyAction) {
                    ForEach(OptionKeyAction.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .settingsHighlight(id: "HUD-Option key behaviour")
                Picker("Progress bar style", selection: $enableGradient) {
                    Text("Hierarchical").tag(false)
                    Text("Gradient").tag(true)
                }
                .settingsHighlight(id: "HUD-Progress bar style")
                Defaults.Toggle(key: .systemEventIndicatorShadow) {
                    Text("Enable glowing effect")
                }
                .settingsHighlight(id: "HUD-Enable glowing effect")
                Defaults.Toggle(key: .systemEventIndicatorUseAccent) {
                    Text("Tint progress bar with accent color")
                }
                .settingsHighlight(id: "HUD-Enable volume HUD")
            } header: {
                Text("General")
            }
            .disabled(!hudReplacement)

            Section {
                Defaults.Toggle(key: .showOpenNotchHUD) {
                    Text("Show HUD in open notch")
                }
                .settingsHighlight(id: "HUD-Show HUD in open notch")
                Defaults.Toggle(key: .showOpenNotchHUDPercentage) {
                    Text("Show percentage")
                }
                .disabled(!Defaults[.showOpenNotchHUD])
            } header: {
                HStack {
                    Text("Open Notch")
                    customBadge(text: "Beta")
                }
            }
            .disabled(!hudReplacement)

            Section {
                Picker("HUD style", selection: $inlineHUD) {
                    Text("Default").tag(false)
                    Text("Inline").tag(true)
                }
                .onChange(of: Defaults[.inlineHUD]) {
                    if Defaults[.inlineHUD] {
                        withAnimation {
                            Defaults[.systemEventIndicatorShadow] = false
                            Defaults[.enableGradient] = false
                        }
                    }
                }
                .settingsHighlight(id: "HUD-HUD style")
                Defaults.Toggle(key: .showClosedNotchHUDPercentage) {
                    Text("Show percentage")
                }
            } header: {
                Text("Closed Notch")
            }
            .disabled(!Defaults[.hudReplacement])
        }
        .accentColor(.effectiveAccent)
        .task {
            accessibilityAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        }
        .onAppear {
            XPCHelperClient.shared.startMonitoringAccessibilityAuthorization()
        }
        .onDisappear {
            XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { notification in
            if let granted = notification.userInfo?["granted"] as? Bool {
                accessibilityAuthorized = granted
            }
        }
    }
}

// MARK: - Media

struct Media: View {
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles
    @Default(.lockScreenWidgetStyle) var lockScreenWidgetStyle
    @Default(.enableLyrics) var enableLyrics

    var body: some View {
        Form {
            Section {
                Picker("Music Source", selection: $mediaController) {
                    ForEach(availableMediaControllers) { controller in
                        Text(controller.rawValue).tag(controller)
                    }
                }
                .onChange(of: mediaController) { _, _ in
                    NotificationCenter.default.post(name: Notification.Name.mediaControllerChanged, object: nil)
                }
                .settingsHighlight(id: "Media-Music source")
            } header: {
                Text("Media Source")
            } footer: {
                if MusicManager.shared.isNowPlayingDeprecated {
                    HStack {
                        Text("YouTube Music requires this third-party app to be installed: ")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Link("https://github.com/pear-devs/pear-desktop", destination: URL(string: "https://github.com/pear-devs/pear-desktop")!)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                } else {
                    Text("'Now Playing' was the only option on previous versions and works with all media apps.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section {
                Toggle("Show music live activity", isOn: $coordinator.musicLiveActivityEnabled.animation())
                    .settingsHighlight(id: "Media-Enable media player")
                Toggle("Show sneak peek on playback changes", isOn: $enableSneakPeek)
                    .settingsHighlight(id: "Media-Show playback controls")
                Picker("Sneak Peek Style", selection: $sneakPeekStyles) {
                    ForEach(SneakPeekStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .settingsHighlight(id: "Media-Sneak peek style")
                HStack {
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("Media inactivity timeout")
                            Spacer()
                            Text("\(Defaults[.waitInterval], specifier: "%.0f") seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .settingsHighlight(id: "Media-Media inactivity timeout")
                Picker(
                    selection: $hideNotchOption,
                    label: HStack {
                        Text("Full screen behavior")
                        customBadge(text: "Beta")
                    }
                ) {
                    Text("Hide for all apps").tag(HideNotchOption.always)
                    Text("Hide for media app only").tag(HideNotchOption.nowPlayingOnly)
                    Text("Never hide").tag(HideNotchOption.never)
                }
                .settingsHighlight(id: "Media-Full screen behavior")
            } header: {
                Text("Media playback live activity")
            }

            Section {
                Defaults.Toggle(key: .lockScreenMusicWidget) {
                    Text("Show music widget on lock screen")
                }
                .settingsHighlight(id: "Media-Show album art")
                Defaults.Toggle(key: .lockScreenExpandedAlbumArt) {
                    HStack {
                        Text("Enable expanded album art")
                        customBadge(text: "Beta")
                    }
                }
                .disabled(!Defaults[.lockScreenMusicWidget])
                .settingsHighlight(id: "Media-Expanded album art")
            } header: {
                Text("Lock screen")
            }

            Section {
                MusicSlotConfigurationView()
                Defaults.Toggle(key: .enableLyrics) {
                    HStack {
                        Text("Show lyrics below artist name")
                        customBadge(text: "Beta")
                    }
                }
                .settingsHighlight(id: "Media-Show lyrics")
            } header: {
                Text("Media controls")
            } footer: {
                Text("Customize which controls appear in the music player. Volume expands when active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
    }

    private var availableMediaControllers: [MediaControllerType] {
        if MusicManager.shared.isNowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }
}

// MARK: - CalendarSettings

struct CalendarSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.autoScrollToNextEvent) var autoScrollToNextEvent

    var body: some View {
        Form {
            Defaults.Toggle(key: .showCalendar) {
                Text("Show calendar")
            }
            .settingsHighlight(id: "Calendar-Show calendar in notch")
            Defaults.Toggle(key: .hideCompletedReminders) {
                Text("Hide completed reminders")
            }
            .settingsHighlight(id: "Calendar-Hide completed reminders")
            Defaults.Toggle(key: .hideAllDayEvents) {
                Text("Hide all-day events")
            }
            .settingsHighlight(id: "Calendar-Hide all-day events")
            Defaults.Toggle(key: .autoScrollToNextEvent) {
                Text("Auto-scroll to next event")
            }
            .settingsHighlight(id: "Calendar-Calendar event count")
            Defaults.Toggle(key: .showFullEventTitles) {
                Text("Always show full event titles")
            }
            .settingsHighlight(id: "Calendar-Always show full event titles")
            Section(header: Text("Calendars")) {
                if calendarManager.calendarAuthorizationStatus != .fullAccess {
                    Text("Calendar access is denied. Please enable it in System Settings.")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Open Calendar Settings") {
                        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                } else {
                    List {
                        ForEach(calendarManager.eventCalendars, id: \.id) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: { calendarManager.getCalendarSelected(calendar) },
                                    set: { isSelected in
                                        Task { await calendarManager.setCalendarSelected(calendar, isSelected: isSelected) }
                                    }
                                )
                            ) {
                                Text(calendar.title)
                            }
                            .tint(Color(calendar.color))
                            .disabled(!showCalendar)
                        }
                    }
                }
            }
            Section(header: Text("Reminders")) {
                if calendarManager.reminderAuthorizationStatus != .fullAccess {
                    Text("Reminder access is denied. Please enable it in System Settings.")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Open Reminder Settings") {
                        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                } else {
                    List {
                        ForEach(calendarManager.reminderLists, id: \.id) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: { calendarManager.getCalendarSelected(calendar) },
                                    set: { isSelected in
                                        Task { await calendarManager.setCalendarSelected(calendar, isSelected: isSelected) }
                                    }
                                )
                            ) {
                                Text(calendar.title)
                            }
                            .tint(Color(calendar.color))
                            .disabled(!showCalendar)
                        }
                    }
                }
            }
        }
        .accentColor(.effectiveAccent)
        .onAppear {
            Task {
                await calendarManager.checkCalendarAuthorization()
                await calendarManager.checkReminderAuthorization()
            }
        }
    }
}

// MARK: - Appearance

struct Appearance: View {
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @Default(.mirrorShape) var mirrorShape
    @Default(.sliderColor) var sliderColor
    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.customVisualizers) var customVisualizers
    @Default(.selectedVisualizer) var selectedVisualizer

    let icons: [String] = ["logo2"]
    @State private var selectedIcon: String = "logo2"
    @State private var selectedListVisualizer: CustomVisualizer? = nil
    @State private var isPresented: Bool = false
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var speed: CGFloat = 1.0

    var body: some View {
        Form {
            Section {
                Toggle("Always show tabs", isOn: $coordinator.alwaysShowTabs)
                    .settingsHighlight(id: "Appearance-Always show tabs")
                Defaults.Toggle(key: .settingsIconInNotch) {
                    Text("Show settings icon in notch")
                }
                .settingsHighlight(id: "Appearance-Show settings icon in notch")
            } header: {
                Text("General")
            }

            Section {
                Defaults.Toggle(key: .coloredSpectrogram) {
                    Text("Colored spectrogram")
                }
                .settingsHighlight(id: "Media-Colored spectrograms")
                Defaults.Toggle("Player tinting", key: .playerColorTinting)
                    .settingsHighlight(id: "Appearance-Player tinting")
                Defaults.Toggle(key: .lightingEffect) {
                    Text("Enable blur effect behind album art")
                }
                .settingsHighlight(id: "Appearance-Enable blur effect")
                Picker("Slider color", selection: $sliderColor) {
                    ForEach(SliderColorEnum.allCases, id: \.self) { option in
                        Text(option.rawValue)
                    }
                }
                .settingsHighlight(id: "Appearance-Slider color")
            } header: {
                Text("Media")
            }

            Section {
                Toggle("Use music visualizer spectrogram", isOn: $useMusicVisualizer.animation())
                    .disabled(true)
                if !useMusicVisualizer {
                    if customVisualizers.count > 0 {
                        Picker("Selected animation", selection: $selectedVisualizer) {
                            ForEach(customVisualizers, id: \.self) { visualizer in
                                Text(visualizer.name).tag(visualizer)
                            }
                        }
                    } else {
                        HStack {
                            Text("Selected animation")
                            Spacer()
                            Text("No custom animation available").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Custom music live activity animation")
                    customBadge(text: "Coming soon")
                }
            }

            Section {
                List {
                    ForEach(customVisualizers, id: \.self) { visualizer in
                        HStack {
                            LottieView(url: visualizer.url, speed: visualizer.speed, loopMode: .loop)
                                .frame(width: 30, height: 30, alignment: .center)
                            Text(visualizer.name)
                            Spacer(minLength: 0)
                            if selectedVisualizer == visualizer {
                                Text("selected")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 8)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.vertical, 2)
                        .background(
                            selectedListVisualizer != nil
                                ? selectedListVisualizer == visualizer ? Color.effectiveAccent : Color.clear
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedListVisualizer == visualizer {
                                selectedListVisualizer = nil
                                return
                            }
                            selectedListVisualizer = visualizer
                        }
                    }
                }
                .safeAreaPadding(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                .frame(minHeight: 120)
                .actionBar {
                    HStack(spacing: 5) {
                        Button {
                            name = ""; url = ""; speed = 1.0; isPresented.toggle()
                        } label: {
                            Image(systemName: "plus").foregroundStyle(.secondary).contentShape(Rectangle())
                        }
                        Divider()
                        Button {
                            if let visualizer = selectedListVisualizer {
                                selectedListVisualizer = nil
                                customVisualizers.remove(at: customVisualizers.firstIndex(of: visualizer)!)
                                if visualizer == selectedVisualizer && customVisualizers.count > 0 {
                                    selectedVisualizer = customVisualizers[0]
                                }
                            }
                        } label: {
                            Image(systemName: "minus").foregroundStyle(.secondary).contentShape(Rectangle())
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(PlainButtonStyle())
                .overlay {
                    if customVisualizers.isEmpty {
                        Text("No custom visualizer")
                            .foregroundStyle(Color(.secondaryLabelColor))
                            .padding(.bottom, 22)
                    }
                }
                .sheet(isPresented: $isPresented) {
                    VStack(alignment: .leading) {
                        Text("Add new visualizer").font(.largeTitle.bold()).padding(.vertical)
                        TextField("Name", text: $name)
                        TextField("Lottie JSON URL", text: $url)
                        HStack {
                            Text("Speed")
                            Spacer(minLength: 80)
                            Text("\(speed, specifier: "%.1f")s").multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                            Slider(value: $speed, in: 0...2, step: 0.1)
                        }
                        .padding(.vertical)
                        HStack {
                            Button { isPresented.toggle() } label: {
                                Text("Cancel").frame(maxWidth: .infinity, alignment: .center)
                            }
                            Button {
                                let visualizer = CustomVisualizer(UUID: UUID(), name: name, url: URL(string: url)!, speed: speed)
                                if !customVisualizers.contains(visualizer) { customVisualizers.append(visualizer) }
                                isPresented.toggle()
                            } label: {
                                Text("Add").frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(BorderedProminentButtonStyle())
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .controlSize(.extraLarge)
                    .padding()
                }
            } header: {
                HStack(spacing: 0) {
                    Text("Custom vizualizers (Lottie)")
                    if !Defaults[.customVisualizers].isEmpty {
                        Text(" – \(Defaults[.customVisualizers].count)").foregroundStyle(.secondary)
                    }
                }
            }
            .settingsHighlight(id: "Advanced-Custom visualizers")

            Section {
                Defaults.Toggle(key: .showMirror) {
                    Text("Enable mirror")
                }
                .disabled(!checkVideoInput())
                .settingsHighlight(id: "Advanced-Enable Dynamic mirror")
                Picker("Mirror shape", selection: $mirrorShape) {
                    Text("Circle").tag(MirrorShapeEnum.circle)
                    Text("Square").tag(MirrorShapeEnum.rectangle)
                }
                .settingsHighlight(id: "Advanced-Mirror shape")
            } header: {
                HStack { Text("Additional features") }
            }
        }
        .accentColor(.effectiveAccent)
    }

    func checkVideoInput() -> Bool {
        AVCaptureDevice.default(for: .video) != nil
    }
}

// MARK: - Widgets

struct Widgets: View {
    @Default(.showCalendar) var showCalendar
    @Default(.showMirror) var showMirror
    @Default(.showHomeView) var showHomeView
    @Default(.showShelfView) var showShelfView
    @Default(.swipeToCycleViews) var swipeToCycleViews
    @ObservedObject var coordinator = KnotchViewCoordinator.shared

    // Swipe-to-cycle only makes sense when both views are enabled
    private var onlyOneViewEnabled: Bool {
        !showHomeView || !showShelfView
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showHomeView) {
                    Text("Home view")
                }
                .disabled(!showShelfView) // can't disable both
                .settingsHighlight(id: "Widgets-Show home view")
                Defaults.Toggle(key: .showShelfView) {
                    Text("Shelf view")
                }
                .disabled(!showHomeView) // can't disable both
                .onChange(of: showShelfView) {
                    // If shelf is disabled while we're on shelf, jump to home
                    if !showShelfView && coordinator.currentView == .shelf {
                        coordinator.currentView = .home
                    }
                }
                .settingsHighlight(id: "Widgets-Show shelf view")
                if onlyOneViewEnabled {
                    Text("Swipe to cycle views is disabled when only one view is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 3) {
                    Text("Notch views")
                    customBadge(text: "Beta")
                }
            } footer: {
                Text("Choose which views are available in the notch. Swipe to cycle is automatically disabled when only one view is enabled.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Toggle("Music player", isOn: $coordinator.musicLiveActivityEnabled.animation())
                    .settingsHighlight(id: "Widgets-Toggle expanded notch widgets")
                Defaults.Toggle(key: .showCalendar) {
                    Text("Calendar")
                }
                .settingsHighlight(id: "Widgets-Show calendar widget")
                Defaults.Toggle(key: .showMirror) {
                    Text("Mirror (camera)")
                }
                .disabled(AVCaptureDevice.default(for: .video) == nil)
                .settingsHighlight(id: "Widgets-Mirror widget")
            } header: {
                HStack(spacing: 6) {
                    Text("Toggle expanded notch widgets")
                    customBadge(text: "Beta")
                }
            } footer: {
                Text("Choose which widgets are shown when the notch is open. If the toolbar doesn't move to the new position, switch notch views (home/tray) and it should reset.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accentColor(.effectiveAccent)
    }
}

// MARK: - Advanced

struct Advanced: View {
    @Default(.useCustomAccentColor) var useCustomAccentColor
    @Default(.customAccentColorData) var customAccentColorData
    @Default(.extendHoverArea) var extendHoverArea
    @Default(.showOnLockScreen) var showOnLockScreen
    @Default(.hideFromScreenRecording) var hideFromScreenRecording

    @State private var customAccentColor: Color = .accentColor
    @State private var selectedPresetColor: PresetAccentColor? = nil
    let icons: [String] = ["logo2"]
    @State private var selectedIcon: String = "logo2"

    enum PresetAccentColor: String, CaseIterable, Identifiable {
        case blue = "Blue"
        case purple = "Purple"
        case pink = "Pink"
        case red = "Red"
        case orange = "Orange"
        case yellow = "Yellow"
        case green = "Green"
        case graphite = "Graphite"

        var id: String { self.rawValue }

        var color: Color {
            switch self {
            case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
            case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
            case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
            case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
            case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
            case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
            case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
            case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Accent color", selection: $useCustomAccentColor) {
                        Text("System").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if !useCustomAccentColor {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                AccentCircleButton(isSelected: true, color: .accentColor, isSystemDefault: true) {}
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Using System Accent").font(.body)
                                    Text("Your macOS system accent color").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Color Presets").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                ForEach(PresetAccentColor.allCases) { preset in
                                    AccentCircleButton(isSelected: selectedPresetColor == preset, color: preset.color, isMulticolor: false) {
                                        selectedPresetColor = preset
                                        customAccentColor = preset.color
                                        saveCustomColor(preset.color)
                                        forceUiUpdate()
                                    }
                                }
                                Spacer()
                            }
                            Divider().padding(.vertical, 4)
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Pick a Color").font(.body)
                                    Text("Choose any color").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                ColorPicker(selection: Binding(
                                    get: { customAccentColor },
                                    set: { newColor in
                                        customAccentColor = newColor
                                        selectedPresetColor = nil
                                        saveCustomColor(newColor)
                                        forceUiUpdate()
                                    }
                                ), supportsOpacity: false) {
                                    ZStack {
                                        Circle().fill(customAccentColor).frame(width: 32, height: 32)
                                        if selectedPresetColor == nil {
                                            Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 2).frame(width: 32, height: 32)
                                        }
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent color")
            } footer: {
                Text("Choose between your system accent color or customize it with your own selection.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .onAppear { initializeAccentColorState() }
            .settingsHighlight(id: "Advanced-Accent color")

            Section {
                Defaults.Toggle(key: .enableShadow) {
                    Text("Enable window shadow")
                }
                .settingsHighlight(id: "Appearance-Enable window shadow")
                //Defaults.Toggle(key: .notchEdgeBlur) {
                //    Text("Progressive edge blur when notch is open")
                //}
                //.settingsHighlight(id: "Appearance-Progressive edge blur")
            } header: {
                Text("Window Appearance")
            }

            Section {
                HStack {
                    ForEach(icons, id: \.self) { icon in
                        Spacer()
                        VStack {
                            Image(icon)
                                .resizable()
                                .frame(width: 80, height: 80)
                                .background(
                                    RoundedRectangle(cornerRadius: 20, style: .circular)
                                        .strokeBorder(icon == selectedIcon ? Color.effectiveAccent : .clear, lineWidth: 2.5)
                                )
                            Text("Default")
                                .fontWeight(.medium)
                                .font(.caption)
                                .foregroundStyle(icon == selectedIcon ? .white : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(icon == selectedIcon ? Color.effectiveAccent : .clear))
                        }
                        .onTapGesture {
                            withAnimation { selectedIcon = icon }
                            NSApp.applicationIconImage = NSImage(named: icon)
                        }
                        Spacer()
                    }
                }
                .disabled(true)
            } header: {
                HStack {
                    Text("App icon")
                    customBadge(text: "Coming soon")
                }
            }

            Section {
                Defaults.Toggle(key: .extendHoverArea) {
                    Text("Extend hover area")
                }
                .settingsHighlight(id: "Advanced-Extend hover area")
                Defaults.Toggle(key: .hideTitleBar) {
                    Text("Hide title bar")
                }
                .settingsHighlight(id: "Advanced-Hide title bar")
                Defaults.Toggle(key: .showOnLockScreen) {
                    Text("Show notch on lock screen")
                }
                .settingsHighlight(id: "Advanced-Show on lock screen")
                Defaults.Toggle(key: .hideFromScreenRecording) {
                    Text("Hide from screen recording")
                }
                .settingsHighlight(id: "Advanced-Hide from screen recording")
            } header: {
                Text("Window Behavior")
            }
        }
        .accentColor(.effectiveAccent)
        .onAppear { loadCustomColor() }
    }

    private func forceUiUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
        }
    }

    private func saveCustomColor(_ color: Color) {
        let nsColor = NSColor(color)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            Defaults[.customAccentColorData] = colorData
            forceUiUpdate()
        }
    }

    private func loadCustomColor() {
        if let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            customAccentColor = Color(nsColor: nsColor)
            selectedPresetColor = nil
            for preset in PresetAccentColor.allCases {
                if colorsAreEqual(Color(nsColor: nsColor), preset.color) {
                    selectedPresetColor = preset
                    break
                }
            }
        }
    }

    private func colorsAreEqual(_ color1: Color, _ color2: Color) -> Bool {
        let c1 = NSColor(color1).usingColorSpace(.sRGB) ?? NSColor(color1)
        let c2 = NSColor(color2).usingColorSpace(.sRGB) ?? NSColor(color2)
        return abs(c1.redComponent - c2.redComponent) < 0.01 &&
               abs(c1.greenComponent - c2.greenComponent) < 0.01 &&
               abs(c1.blueComponent - c2.blueComponent) < 0.01
    }

    private func initializeAccentColorState() {
        if !useCustomAccentColor {
            selectedPresetColor = nil
        } else {
            loadCustomColor()
        }
    }
}

// MARK: - Shortcuts

struct Shortcuts: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle Sneak Peek:", name: .toggleSneakPeek)
                    .settingsHighlight(id: "Shortcuts-Toggle Sneak Peek")
            } header: {
                Text("Media")
            } footer: {
                Text("Sneak Peek shows the media title and artist under the notch for a few seconds.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Section {
                KeyboardShortcuts.Recorder("Toggle Notch Open:", name: .toggleNotchOpen)
                    .settingsHighlight(id: "Shortcuts-Toggle notch open")
            }
        }
        .accentColor(.effectiveAccent)
    }
}

// MARK: - Shelf

struct Shelf: View {
    @Default(.shelfTapToOpen) var shelfTapToOpen: Bool
    @Default(.quickShareProvider) var quickShareProvider
    @Default(.expandedDragDetection) var expandedDragDetection: Bool
    @StateObject private var quickShareService = QuickShareService.shared

    private var selectedProvider: QuickShareProvider? {
        quickShareService.availableProviders.first(where: { $0.id == quickShareProvider })
    }

    init() {
        Task { await QuickShareService.shared.discoverAvailableProviders() }
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .knotchShelf) {
                    Text("Enable shelf")
                }
                .settingsHighlight(id: "Shelf-Enable shelf")
                Defaults.Toggle(key: .openShelfByDefault) {
                    Text("Open shelf by default if items are present")
                }
                .settingsHighlight(id: "Shelf-Open shelf by default")
                Defaults.Toggle(key: .expandedDragDetection) {
                    Text("Expanded drag detection area")
                }
                .onChange(of: expandedDragDetection) {
                    NotificationCenter.default.post(name: Notification.Name.expandedDragDetectionChanged, object: nil)
                }
                .settingsHighlight(id: "Shelf-Expanded drag detection")
                Defaults.Toggle(key: .copyOnDrag) {
                    Text("Copy items on drag")
                }
                .settingsHighlight(id: "Shelf-Copy items on drag")
                Defaults.Toggle(key: .autoRemoveShelfItems) {
                    Text("Remove from shelf after dragging")
                }
                .settingsHighlight(id: "Shelf-Remove after dragging")
            } header: {
                HStack { Text("General") }
            }

            Section {
                Picker("Quick Share Service", selection: $quickShareProvider) {
                    ForEach(quickShareService.availableProviders, id: \.id) { provider in
                        HStack {
                            if let imgData = provider.imageData, let nsImg = NSImage(data: imgData) {
                                Image(nsImage: nsImg).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "square.and.arrow.up").frame(width: 16, height: 16).foregroundColor(.accentColor)
                            }
                            Text(provider.id)
                        }
                        .tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                .settingsHighlight(id: "Shelf-Shelf activation gesture")
                if let selectedProvider = selectedProvider {
                    HStack {
                        Group {
                            if let imgData = selectedProvider.imageData, let nsImg = NSImage(data: imgData) {
                                Image(nsImage: nsImg).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .frame(width: 16, height: 16)
                        .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Currently selected: \(selectedProvider.id)").font(.caption).foregroundColor(.secondary)
                            Text("Files dropped on the shelf will be shared via this service").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack { Text("Quick Share") }
            } footer: {
                Text("Choose which service to use when sharing files from the shelf. Click the shelf button to select files, or drag files onto it to share immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
    }
}

// MARK: - About

struct About: View {
    @State private var showBuildNumber: Bool = false
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Release name")
                        Spacer()
                        Text(Defaults[.releaseName]).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))").foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "unknown").foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation { showBuildNumber.toggle() }
                    }
                } header: {
                    Text("Version info")
                }
                UpdaterSettingsView(updater: updaterController.updater)
                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        if let url = URL(string: "https://github.com/seshyweshyy/Knotch") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github").resizable().aspectRatio(contentMode: .fit).frame(width: 18)
                            Text("GitHub")
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
            }
            VStack(spacing: 0) {
                Divider()
                Text("Made by seshyweshyy")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .toolbar {
            CheckForUpdatesView(updater: updaterController.updater)
        }
    }
}

// MARK: - Helpers

func lighterColor(from nsColor: NSColor, amount: CGFloat = 0.14) -> Color {
    let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    func lighten(_ c: CGFloat) -> CGFloat { min(max(c + (1.0 - c) * amount, 0), 1) }
    return Color(red: Double(lighten(r)), green: Double(lighten(g)), blue: Double(lighten(b)), opacity: Double(a))
}

// MARK: - Accent Circle Button

struct AccentCircleButton: View {
    let isSelected: Bool
    let color: Color
    var isSystemDefault: Bool = false
    var isMulticolor: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).frame(width: 32, height: 32)
                Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1).frame(width: 32, height: 32)
                if isSelected {
                    Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 2).frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isSystemDefault ? "Use your macOS system accent color" : "")
    }
}

// MARK: - Badges

func proFeatureBadge() -> some View {
    Text("Upgrade to Pro")
        .foregroundStyle(Color(red: 0.545, green: 0.196, blue: 0.98))
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.545, green: 0.196, blue: 0.98), lineWidth: 1))
}

func comingSoonTag() -> some View {
    Text("Coming soon")
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func customBadge(text: String) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func warningBadge(_ text: String, _ description: String) -> some View {
    Section {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text(text).font(.headline)
                Text(description).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

#Preview {
    HUD()
}
