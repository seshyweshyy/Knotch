//
//  KnotchSkyLightWindow.swift
//  Knotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class KnotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)

        // NSGlassEffectView's backdrop capture goes stale after this window
        // moves spaces (enableSkyLight) and again whenever the frontmost app
        // changes. It only refreshes on a "became key" event, so re-trigger
        // that momentarily whenever the backdrop content behind us changes.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.refreshGlassBackdrop()
            }
            .store(in: &observers)

        // TEMP DIAGNOSTIC EXPERIMENT — remove once the every-open X-drift bug
        // is root-caused. Measured pixel data shows the glass's own edge/
        // lensing boundary (not vm.notchSize, not corner radius — both
        // confirmed to change exactly once, cleanly) keeps drifting for
        // ~200ms after the panel's width has already settled, specifically
        // near the top where the glass highlight is concentrated. Given the
        // backdrop-capture staleness this class already works around above,
        // this tests whether the SAME staleness — now triggered by the
        // panel's own resize, not just space/app changes — explains it.
        NotificationCenter.default
            .publisher(for: .knotchWillOpen)
            .sink { [weak self] _ in
                self?.refreshGlassBackdrop()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readOnly
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
            refreshGlassBackdrop()
        }
    }

    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }

    // Momentarily takes key status to force NSGlassEffectView to resample
    // its backdrop, then immediately hands key status back so we don't
    // steal keyboard focus from another window in the app (e.g. Settings).
    // Safe to call opportunistically; .nonactivatingPanel means becoming
    // key here never activates the app or steals focus from other apps.
    // Not gated on isSkyLightEnabled: this window only enables SkyLight
    // while the screen is locked, but the glass needs the same refresh in
    // ordinary (unlocked) use, where SkyLight is never engaged at all.
    func refreshGlassBackdrop() {
        guard isVisible else { return }
        let previousKeyWindow = NSApp.keyWindow
        makeKey()
        if let previousKeyWindow, previousKeyWindow !== self {
            previousKeyWindow.makeKey()
        }
    }

    private var observers: Set<AnyCancellable> = []

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    // TEMP DIAGNOSTIC EXPERIMENT — remove once the every-open X-drift bug is
    // root-caused. Posted from KnotchViewModel.open() to test whether
    // NSGlassEffectView's backdrop-capture staleness (see setupObservers()
    // above) also applies to the panel's own resize, not just space/app
    // changes.
    static let knotchWillOpen = Notification.Name("com.Knotch.knotchWillOpen")
}
