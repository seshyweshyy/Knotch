//
//  SettingsWindowController.swift
//  Knotch
//
//  Created by Alexander on 2025-06-14.
//

import AppKit
import SwiftUI
import Defaults
import Sparkle

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private var updater: SPUUpdater?
    
    private init() {
        let window = KnotchSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.setValue(25, forKey: "cornerRadius")
        
        super.init(window: window)
        
        setupWindow()
    }
    
    final class KnotchSettingsWindow: NSWindow {
        // Adjust these to taste
        private let trafficLightX: CGFloat = 18
        private let trafficLightY: CGFloat = 18  // distance from top of window

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            super.setFrame(frameRect, display: flag)
            repositionTrafficLights()
        }

        override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
            super.setFrame(frameRect, display: flag, animate: animate)
            repositionTrafficLights()
        }

        private func repositionTrafficLights() {
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let spacing: CGFloat = 23

            for (i, type) in types.enumerated() {
                guard let button = standardWindowButton(type),
                      let superview = button.superview else { continue }
                let buttonHeight = button.frame.height
                // superview coords: y=0 is bottom of titlebar superview
                let newY = superview.frame.height - trafficLightY - buttonHeight
                button.setFrameOrigin(NSPoint(x: trafficLightX + CGFloat(i) * spacing, y: newY))
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setUpdater(_ updater: SPUUpdater) {
        self.updater = updater
        // Don't rebuild the window — content is loaded lazily on first showWindow()
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = "Knotch Settings"
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("KnotchSettingsWindow")
        
        // Start with an empty view — content is loaded lazily on first show
        window.contentView = NSView()
        
        window.delegate = self
    }
    
    private func loadContentIfNeeded() {
        guard let window = window,
              !(window.contentView is NSVisualEffectView) else { return }

        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active

        let hostingView = NSHostingView(rootView: SettingsView(updater: updater))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])

        window.contentView = effectView
    }
    
    func showWindow() {
        loadContentIfNeeded()
        
        // If window is already visible, bring it (and the app) to the front
        if window?.isVisible == true {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
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
