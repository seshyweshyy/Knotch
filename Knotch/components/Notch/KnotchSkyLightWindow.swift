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

        // Same backdrop-capture staleness this class already works around
        // above (space/app switches), just triggered by the panel's own
        // open resize instead. Without this, the glass's edge/lensing kept
        // visibly drifting for ~200ms after the panel's width had already
        // settled — confirmed via pixel measurement that neither
        // vm.notchSize nor the corner radii were the cause (both change
        // exactly once, cleanly); it was specifically the glass material
        // catching up to geometry it already had.
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
    // its backdrop, then hands key status back so we don't steal keyboard
    // focus from another window in the app (e.g. Settings). Safe to call
    // opportunistically; .nonactivatingPanel means becoming key here never
    // activates the app or steals focus from other apps. Not gated on
    // isSkyLightEnabled: this window only enables SkyLight while the screen
    // is locked, but the glass needs the same refresh in ordinary
    // (unlocked) use, where SkyLight is never engaged at all.
    func refreshGlassBackdrop() {
        guard isVisible else { return }
        let previousKeyWindow = NSApp.keyWindow
        makeKey()
        guard let previousKeyWindow, previousKeyWindow !== self else { return }
        // Delayed rather than synchronous — becoming key only triggers the
        // resample, it doesn't block until the window server finishes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
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
