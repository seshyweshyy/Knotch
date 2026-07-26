//
//  Constants.swift
//  Knotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

struct CustomVisualizer: Codable, Hashable, Equatable, Defaults.Serializable {
    let UUID: UUID
    var name: String
    var url: URL
    var speed: CGFloat = 1.0
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum CalendarApp: String, CaseIterable, Identifiable, Defaults.Serializable {
    case apple       = "Apple Calendar"
    case fantastical = "Fantastical"
    case busyCal     = "BusyCal"
    case notionCal   = "Notion Calendar"

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .apple:       return "com.apple.iCal"
        case .fantastical: return "com.flexibits.fantastical2.mac"
        case .busyCal:     return "com.busymac.busycal3"
        case .notionCal:   return "notion.id"
        }
    }

    var isInstalled: Bool {
        switch self {
        case .apple:       return true
        case .fantastical, .busyCal, .notionCal:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        }
    }
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

// Define notification names at file scope
extension Notification.Name {
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
    static let musicPreviousButtonAnimationTriggered = Notification.Name("musicPreviousButtonAnimationTriggered")
    static let musicNextButtonAnimationTriggered = Notification.Name("musicNextButtonAnimationTriggered")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case youtubeMusic = "YouTube Music"

    var id: String { self.rawValue }

    // Bundle identifier of the concrete app behind this controller, used to
    // launch it when there's no currently active music source. `nowPlaying`
    // aggregates other apps rather than being an app itself, so it has none.
    var bundleIdentifier: String? {
        switch self {
        case .nowPlaying: return nil
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .youtubeMusic: return YouTubeMusicConfiguration.default.bundleIdentifier
        }
    }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "Default"
    case inline = "Inline"
    
    var id: String { self.rawValue }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings = "Open System Settings"
    case showHUD = "Show HUD"
    case none = "No Action"

    var id: String { self.rawValue }
}

enum BluetoothHUDIconStyle: String, Defaults.Serializable, CaseIterable {
    case symbol = "Symbol"
    case threeDimensional = "3D"
}

enum NotchAppearanceStyle: String, Defaults.Serializable, CaseIterable {
    case solidBlack = "Solid Black"
    case semiLiquidGlass = "Semi Liquid Glass"
    case fullLiquidGlass = "Full Liquid Glass"
}

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let enableCompactUI = Key<Bool>("enableCompactUI", default: false)
    static let compactShowMusicView = Key<Bool>("compactShowMusicView", default: true)
    static let compactShowCalendarView = Key<Bool>("compactShowCalendarView", default: true)
    static let compactShowReminders = Key<Bool>("compactShowReminders", default: true)
    static let compactShowAllDayEvents = Key<Bool>("compactShowAllDayEvents", default: true)

    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: true)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Appearance
    static let showEmojis = Key<Bool>("showEmojis", default: false)
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let showTimer = Key<Bool>("showTimer", default: true)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let notchAppearanceStyle = Key<NotchAppearanceStyle>("notchAppearanceStyle", default: .solidBlack)
    static let semiLiquidGlassTransition = Key<Double>("semiLiquidGlassTransition", default: 0.5)
    
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: true)
    static let calendarApp = Key<CalendarApp>("calendarApp", default: .apple)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)
    static let showAppIconOnAlbumArt = Key<Bool>("showAppIconOnAlbumArt", default: false)
    static let useMusicVisualizer = Key<Bool>("useMusicVisualizer", default: true)
    static let selectedVisualizer = Key<CustomVisualizer?>("selectedVisualizer", default: nil)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let swipeToCycleViews = Key<Bool>("swipeToCycleViews", default: true)
    static let changeMediaWithHorizontalGestures = Key<Bool>("changeMediaWithHorizontalGestures", default: false)
    static let naturalMediaGestureDirection = Key<Bool>("naturalMediaGestureDirection", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)

    // MARK: Notch Views
    static let showHomeView = Key<Bool>("showHomeView", default: true)
    static let showShelfView = Key<Bool>("showShelfView", default: true)
    
    // MARK: Media playback
    static let homeViewVisualizer = Key<Bool>("homeViewVisualizer", default: true)
    static let sneakPeekOnTrackChange = Key<Bool>("sneakPeekOnTrackChange", default: false)
    static let sneakPeekOnResume = Key<Bool>("sneakPeekOnResume", default: false)
    // Legacy single toggle, kept only so its value can be migrated into the two keys above.
    static let legacyEnableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let hasMigratedSneakPeekSplit = Key<Bool>("hasMigratedSneakPeekSplit", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let sneakPeekMusicDuration = Key<Double>("sneakPeekMusicDuration", default: 3.0)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    static let lockScreenMusicWidget = Key<Bool>("lockScreenMusicWidget", default: true)
    static let lockScreenExpandedAlbumArt = Key<Bool>("lockScreenExpandedAlbumArt", default: true)
    static let keepAwakeOnExpandedArt = Key<Bool>("keepAwakeOnExpandedArt", default: true)
    static let lockScreenTimerWidget = Key<Bool>("lockScreenTimerWidget", default: true)
    
    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    static let showBatteryPercentageAsIcon = Key<Bool>("showBatteryPercentageAsIcon", default: false)
    
    // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon)
    
    // MARK: HUD
    static let hudReplacement = Key<Bool>("hudReplacement", default: false)
    static let bluetoothHUDIconStyle = Key<BluetoothHUDIconStyle>("bluetoothHUDIconStyle", default: .threeDimensional)
    static let inlineHUD = Key<Bool>("inlineHUD", default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchHUD = Key<Bool>("showOpenNotchHUD", default: true)
    static let showOpenNotchHUDPercentage = Key<Bool>("showOpenNotchHUDPercentage", default: true)
    static let showClosedNotchHUDPercentage = Key<Bool>("showClosedNotchHUDPercentage", default: false)
    static let hudOvershootEnabled = Key<Bool>("hudOvershootEnabled", default: true)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    static let showBluetoothDeviceConnections = Key<Bool>("showBluetoothDeviceConnections", default: true)

    // MARK: Focus
    static let showFocusModeIndicator = Key<Bool>("showFocusModeIndicator", default: true)
    static let useDetailedFocusMetadata = Key<Bool>("useDetailedFocusMetadata", default: true)

    // MARK: AirDrop
    static let showAirDropReceiveProgress = Key<Bool>("showAirDropReceiveProgress", default: true)

    // MARK: Shelf
    static let knotchShelf = Key<Bool>("knotchShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let shelfTapToOpen = Key<Bool>("shelfTapToOpen", default: true)
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.defaultProvider.id)
    static let localSendSelectedDeviceID = Key<String>("localSendSelectedDeviceID", default: "")
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    
    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    
    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)
    
    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    static let defaultPlayer = Key<MediaControllerType>("defaultPlayer", default: .appleMusic)
    static let liveWaveform = Key<Bool>("liveWaveform", default: false)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    
    // Helper to determine the default media controller based on NowPlaying deprecation status
    static var defaultMediaController: MediaControllerType {
        if MusicManager.shared.isNowPlayingDeprecated {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
