//
//  SettingsWindowController.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-14.
//

import AppKit
import SwiftUI
import Defaults
import Sparkle

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private var updaterController: SPUStandardUpdaterController?
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setUpdaterController(_ controller: SPUStandardUpdaterController) {
        self.updaterController = controller
        // Don't rebuild the window — content is loaded lazily on first showWindow()
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = "Knotch Settings"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("BoringNotchSettingsWindow")
        
        // Start with an empty view — content is loaded lazily on first show
        window.contentView = NSView()
        
        window.delegate = self
    }
    
    private func loadContentIfNeeded() {
        guard let window = window,
              !(window.contentView is NSHostingView<SettingsView>) else { return }
        let settingsView = SettingsView(updaterController: updaterController)
        window.contentView = NSHostingView(rootView: settingsView)
    }
    
    func showWindow() {
        loadContentIfNeeded()
        
        // If window is already visible, bring it to front
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        
        // Defer activation policy change to avoid a CPU spike on open
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
        }
    }
    
    override func close() {
        super.close()
        relinquishFocus()
    }
    
    private func relinquishFocus() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        
        // Tear down the content view so @Default subscriptions and timers don't run in the background
        window?.contentView = NSView()
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocus()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    
    func windowDidResignKey(_ notification: Notification) {
    }
}
