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
    @MainActor
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
    private var holdsActiveAppearanceLease = false

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

        // Refresh the known glass views without changing keyboard ownership.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.refreshGlassBackdrop() }
            .store(in: &observers)

        for name in [Notification.Name.knotchWillOpen, .knotchWillClose] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refreshGlassBackdrop() }
                .store(in: &observers)
        }
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

    func refreshGlassBackdrop() {
        guard isVisible else { return }
        acquireActiveGlassAppearance()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        refreshGlassBackdrop()
    }

    override func orderOut(_ sender: Any?) {
        releaseActiveGlassAppearance()
        super.orderOut(sender)
    }

    override func close() {
        releaseActiveGlassAppearance()
        super.close()
    }

    /// Gives NSGlassEffectView the visual state of a key/main window without
    /// changing WindowServer keyboard routing. The lease is held for the
    /// visible lifetime of the overlay and released during teardown.
    func acquireActiveGlassAppearance() {
        setPrivateBool(true, selectorName: "_setForceActiveControls:")
        setPrivateBool(true, selectorName: "_setHasActiveAppearance:")
        setPrivateBool(true, selectorName: "_setForceMainAppearance:")

        if !holdsActiveAppearanceLease {
            callPrivateVoid("acquireKeyAppearance")
            callPrivateVoid("acquireMainAppearance")
            holdsActiveAppearanceLease = true
        }

        callPrivateVoid("_sendForcedWindowChangedKeyState")
        NotificationCenter.default.post(name: .knotchGlassAppearanceNeedsRefresh, object: self)
    }

    func releaseActiveGlassAppearance() {
        guard holdsActiveAppearanceLease else { return }
        callPrivateVoid("resignKeyAppearance")
        callPrivateVoid("resignMainAppearance")
        holdsActiveAppearanceLease = false
        setPrivateBool(false, selectorName: "_setForceMainAppearance:")
        setPrivateBool(false, selectorName: "_setHasActiveAppearance:")
        setPrivateBool(false, selectorName: "_setForceActiveControls:")
    }

    private func setPrivateBool(_ value: Bool, selectorName: String) {
        let selector = NSSelectorFromString(selectorName)
        guard responds(to: selector),
              let method = class_getInstanceMethod(type(of: self), selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        function(self, selector, value)
    }

    private func callPrivateVoid(_ selectorName: String) {
        let selector = NSSelectorFromString(selectorName)
        guard responds(to: selector),
              let method = class_getInstanceMethod(type(of: self), selector) else { return }
        typealias Action = @convention(c) (AnyObject, Selector) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Action.self)
        function(self, selector)
    }

    private var observers: Set<AnyCancellable> = []

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    // Geometry changes refresh material sampling without taking focus.
    static let knotchWillOpen = Notification.Name("com.Knotch.knotchWillOpen")
    static let knotchWillClose = Notification.Name("com.Knotch.knotchWillClose")
}
