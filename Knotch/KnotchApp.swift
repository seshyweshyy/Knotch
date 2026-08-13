//
//  KnotchApp.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI
import AlbumArtBackgroundWindow
import os

@main
struct KnotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updater: SPUUpdater
    private let updateUserDriver: KnotchUpdateUserDriver

    init() {
        let userDriver = KnotchUpdateUserDriver()
        updateUserDriver = userDriver
        updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: nil)
        do {
            try updater.start()
        } catch {
            Logger(subsystem: "seshyweshyy.Knotch", category: "Updater").error("Failed to start Sparkle updater: \(error)")
        }

        // Initialize the settings window controller with the updater
        SettingsWindowController.shared.setUpdater(updater)
    }

    var body: some Scene {
        MenuBarExtra("Knotch", image: "MenuBarIcon", isInserted: $showMenuBarIcon) {
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("Version \(version)")
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView(updater: updater)
            Divider()
            Button {
                ApplicationRelauncher.restart()
            } label: {
                Label("Restart Knotch", systemImage: "arrow.counterclockwise")
            }
            Button(role: .destructive) {
                NSApplication.shared.terminate(self)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: KnotchViewModel] = [:] // UUID -> KnotchViewModel
    var window: NSWindow?
    let vm: KnotchViewModel = .init()
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var windowScreenDidChangeObserver: Any?
    private var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector
    private var cancellables = Set<AnyCancellable>()
    // Debounces handleDragExitsNotchRegion for Compact mode's drag overlay —
    // DragDetector's own notchRegion is hand-computed from openNotchSize
    // rather than read off the compact panel's actual on-screen frame, so a
    // mouse position right at that boundary can flap in/out for a moment even
    // while the cursor visibly stays over the panel. A same-tick close would
    // fire on every one of those transient exits; waiting a beat and
    // re-checking lets a follow-up re-entry cancel it out first.
    private var compactDragExitDebounceTask: Task<Void, Never>?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowController.shared.showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        cleanupDragDetectors()
        cleanupWindows()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
    }

    @MainActor
    private func showLiquidGlassWidgetIfNeeded() {
        guard Defaults[.lockScreenMusicWidget] else { return }
        guard let bundleID = MusicManager.shared.bundleIdentifier,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        LiquidGlassWidgetWindowController.shared.show(on: screen)
        let colorPublisher = MusicManager.shared.$artFlipSignal
            .map { $0.art }
            .flatMap { image -> AnyPublisher<[Color], Never> in
                Future { promise in
                    image.dominantColors(count: 3) { nsColors in
                        let colors = nsColors.map { Color(nsColor: $0) }
                        promise(.success(colors))
                    }
                }.eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
        let motionArtPublisher = MusicManager.shared.$lockScreenMotionArtURL.eraseToAnyPublisher()
        AlbumArtBackgroundWindowController.shared.prepare(on: screen, colorPublisher: colorPublisher, motionArtPublisher: motionArtPublisher)
        AlbumArtBackgroundWindowController.shared.setSharingType(
            Defaults[.hideFromScreenRecording] ? .none : .readOnly
        )
    }

    let lockAnimationHost = LockAnimationHost()

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        closeOpenNotches()
        broadcastLockState(true)
        enableSkyLightOnAllWindows()
        showLiquidGlassWidgetIfNeeded()
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        LiquidGlassTimerWidgetWindowController.shared.screenDidLock(on: screen)
        LockScreenMiniWidgetRowWindowController.shared.screenDidLock(on: screen)
        lockAnimationHost.play(forward: false)
    }
    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        broadcastLockState(false)
        disableSkyLightOnAllWindows()
        LiquidGlassWidgetWindowController.shared.hide()
        LiquidGlassTimerWidgetWindowController.shared.screenDidUnlock()
        LockScreenMiniWidgetRowWindowController.shared.screenDidUnlock()
    }
    
    @MainActor
    private func closeOpenNotches() {
        if Defaults[.showOnAllDisplays] {
            for viewModel in viewModels.values where viewModel.notchState == .open {
                viewModel.close()
            }
        } else if vm.notchState == .open {
            vm.close()
        }
    }

    private func broadcastLockState(_ locked: Bool) {
        if locked {
            coordinator.isScreenLocked = true
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                vm.isScreenLocked = true
            }
            for viewModel in viewModels.values {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                    viewModel.isScreenLocked = true
                }
            }
        } else {
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                await MainActor.run {
                    coordinator.isScreenLocked = false
                    // Set isUnlockAnimating BEFORE isScreenLocked goes false
                    // so NotchLayout never sees a frame where both are false
                    vm.isUnlockAnimating = true
                    vm.isScreenLocked = false
                    for viewModel in viewModels.values {
                        viewModel.isUnlockAnimating = true
                        viewModel.isScreenLocked = false
                    }
                }
            }
        }
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? KnotchSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? KnotchSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    self.windows.values.forEach { window in
                        if let skyWindow = window as? KnotchSkyLightWindow {
                            skyWindow.disableSkyLight()
                        }
                    }
                } else {
                    if let skyWindow = self.window as? KnotchSkyLightWindow {
                        skyWindow.disableSkyLight()
                    }
                }
            }
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            windows.values.forEach { window in
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            window.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            self.window = nil
        }
    }

    private func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        guard Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame
        let notchHeight = openNotchSize.height
        let notchWidth = openNotchSize.width
        
        // Create notch region at the top-center of the screen where an open notch would occupy
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }

        detector.onDragExitsNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragExitsNotchRegion(onScreen: screen)
            }
        }

        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }

        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            beginDragOverlay(for: viewModel)
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, screen == windowScreen {
            beginDragOverlay(for: vm)
        }
    }

    private func beginDragOverlay(for viewModel: KnotchViewModel) {
        // A re-entry (including a flapping one right on the detection
        // boundary) supersedes any pending debounced exit-close.
        compactDragExitDebounceTask?.cancel()
        compactDragExitDebounceTask = nil

        guard Defaults[.enableCompactUI] else {
            viewModel.open()
            coordinator.currentView = .tray
            return
        }

        // File Drop View is the master switch for the whole drag-and-drop
        // overlay — off means dragging a file near the notch does nothing
        // at all, regardless of the individual square settings below it.
        guard Defaults[.compactShowFileDropView] else { return }

        // If every square is individually disabled, the overlay would have
        // nothing to show — skip it entirely rather than popping open an
        // empty drop zone.
        let anySquareVisible = Defaults[.compactShowQuickShareSquare]
            || Defaults[.compactShowTraySquare]
            || Defaults[.compactShowConverterSquare]
        guard anySquareVisible else { return }

        // Live-activity-style: morph whatever compact page is showing into a
        // drop zone instead of switching to the (compact-mode-unreachable)
        // tray tab. If the notch was closed, remember that so a drag that
        // exits without dropping can close it back up rather than leaving it
        // open on whatever compact page it fell back to.
        if viewModel.notchState == .closed {
            viewModel.isCompactDragAutoOpened = true
        }
        // Fences out every *unrelated* auto-close trigger (hover-exit,
        // popover changes, sharingDidFinish, ...) for as long as this drag
        // stays near the notch — see KnotchViewModel.close(), which already
        // checks this same flag. Without it, the notch never got a real
        // SwiftUI hover event (it was opened programmatically here, not via
        // .onHover), so ContentView's own hover-exit close path was free to
        // fire mid-drag with no idea a drop was in progress. Matched by
        // finishCompactDragOverlay's endInteraction; guarded so a
        // redundant/duplicate enter event while already active doesn't
        // double up the reference count.
        if !viewModel.isCompactDragOverlayActive {
            SharingStateManager.shared.beginInteraction()
        }
        // Set before open(), not after — open() is what first mounts
        // NotchHomeView (via ContentView's `if vm.notchState == .open`), and
        // its very first body evaluation needs isCompactDragOverlayActive
        // already true to render the drop-zone squares directly. Setting it
        // afterward left a one-frame (sometimes longer, on a cold first drag
        // of the session) window where the notch opened straight onto
        // whatever compactPage defaulted to instead.
        viewModel.isCompactDragOverlayActive = true
        viewModel.isCompactDragCommitted = false
        viewModel.open()
    }

    private func handleDragExitsNotchRegion(onScreen screen: NSScreen) {
        guard Defaults[.enableCompactUI] else { return }
        guard let uuid = screen.displayUUID else { return }

        let viewModel: KnotchViewModel?
        if Defaults[.showOnAllDisplays] {
            viewModel = viewModels[uuid]
        } else if let windowScreen = window?.screen, screen == windowScreen {
            viewModel = vm
        } else {
            viewModel = nil
        }

        // A drop already landed on one of the three squares and is mid-async
        // work (e.g. Converter resolving the file URL) — let its own
        // completion handler decide what happens next instead of treating
        // this as an abandoned drag.
        guard let viewModel, viewModel.isCompactDragOverlayActive, !viewModel.isCompactDragCommitted else { return }

        // Debounced rather than acted on immediately — see
        // compactDragExitDebounceTask's declaration for why a same-tick close
        // here is too eager. A follow-up re-entry (beginDragOverlay) cancels
        // this before it fires; only a genuinely abandoned drag survives long
        // enough to actually close the notch.
        compactDragExitDebounceTask?.cancel()
        compactDragExitDebounceTask = Task { @MainActor [weak viewModel] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let viewModel else { return }
            guard viewModel.isCompactDragOverlayActive, !viewModel.isCompactDragCommitted else { return }
            viewModel.finishCompactDragOverlay()
        }
    }

    private func createKnotchWindow(for screen: NSScreen, with viewModel: KnotchViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = KnotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        
        // Enable SkyLight only when screen is locked
        if isScreenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
                .environmentObject(lockAnimationHost)
        )

        window.orderFrontRegardless()
        (window as? KnotchSkyLightWindow)?.refreshGlassBackdrop()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }

    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.previewOnboardingRequested, object: nil, queue: nil
        ) { [weak self] notification in
            let step = notification.userInfo?["step"] as? OnboardingStep ?? .welcome
            Task { @MainActor in
                self?.showOnboardingWindow(step: step)
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }
        
        MusicManager.shared.$bundleIdentifier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bundleID in
                guard let self = self, self.isScreenLocked else { return }
                let appIsRunning = bundleID.flatMap { id in
                    NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id })
                } != nil
                if appIsRunning {
                    self.showLiquidGlassWidgetIfNeeded()
                } else {
                    LiquidGlassWidgetWindowController.shared.hide()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.hideFromScreenRecording)
            .sink { change in
                AlbumArtBackgroundWindowController.shared.setSharingType(
                    change.newValue ? .none : .readOnly
                )
            }
            .store(in: &cancellables)

        _ = BluetoothAudioManager.shared
        _ = FocusModeManager.shared
        _ = AirDropReceiveManager.shared

        // Requested at normal launch (while unlocked) rather than only on
        // lock — the location permission prompt can't be interacted with
        // once the screen is actually locked, so waiting until lock would
        // mean the weather mini-widget never gets authorized.
        WeatherManager.shared.refreshIfNeeded()

        // CalendarManager.events otherwise only populates once the notch's
        // own calendar view or Settings' Calendar tab has appeared — prime
        // it here too so the lock-screen Calendar mini-widget has data even
        // if neither of those has been opened yet this session.
        if Defaults[.lockScreenCalendarMiniWidget] {
            CalendarManager.shared.scheduleUpdate(for: Date())
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    await MainActor.run {
                        viewModel.open()
                    }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            let window = createKnotchWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }

        previousScreens = NSScreen.screens
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "welcome", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWindows()
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = windows[uuid] {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = KnotchViewModel(screenUUID: uuid)
                    let window = createKnotchWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID
            vm.notchSize = getClosedNotchSize(screenUUID: selectedScreen.displayUUID)

            if window == nil {
                window = createKnotchWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                }
            }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
            (window as? KnotchSkyLightWindow)?.refreshGlassBackdrop()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    // Always rebuilds rather than reusing onboardingWindowController, since a
    // prior window may have already been closed (and thus released) by
    // onFinish — reusing it would show a stale/dead window.
    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        onboardingWindowController?.window?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Onboarding"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(
            rootView: OnboardingView(
                step: step,
                onFinish: {
                    window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                    window.close()
                    NSApp.deactivate()
                },
                onOpenSettings: {
                    window.close()
                    SettingsWindowController.shared.showWindow()
                }
            ))
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 30
        window.contentView?.layer?.masksToBounds = true

        onboardingWindowController = NSWindowController(window: window)

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
    static let previewOnboardingRequested = Notification.Name("previewOnboardingRequested")
}
