//
//  UpdateWindowController.swift
//  Knotch
//

import AppKit
import SwiftUI

/// Hosts the custom update UI. Styling is a placeholder for this pass —
/// matching the designed windows (checking / found states) comes later.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onWindowClosedWithoutChoice: () -> Void
    private var choiceMade = false
    private var resizeObserver: Any?

    init(state: UpdateFlowState, onWindowClosedWithoutChoice: @escaping () -> Void) {
        self.onWindowClosedWithoutChoice = onWindowClosedWithoutChoice

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        // Same private-key trick Settings' window uses to round beyond the system default.
        window.setValue(20, forKey: "cornerRadius")
        super.init()
        window.delegate = self

        // Content can grow after the window is already shown (e.g. release
        // notes arriving asynchronously on the found-update screen), so
        // re-run positioning whenever the window's size actually changes —
        // not just once in show(). Repositioning only changes the origin
        // (not size), so this doesn't retrigger itself.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.positionWindow()
        }

        // Lighter, more see-through material than Settings' `.sidebar`.
        let effectView = NSVisualEffectView()
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active

        let hostingView = NSHostingView(rootView: UpdateWindowView(state: state) { [weak self] in
            self?.markChoiceMade()
            self?.window.close()
        })
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

    func show() {
        choiceMade = false
        NSApp.activate(ignoringOtherApps: true)
        positionWindow()
        window.makeKeyAndOrderFront(nil)
    }

    /// Centers horizontally, but sits a bit above dead-center vertically —
    /// called on every `show()` (not just once) since the window's height
    /// varies a lot across phases (a short "checking" dialog vs. the much
    /// taller found-update screen with release notes).
    private func positionWindow() {
        window.layoutIfNeeded()
        guard let screen = window.screen ?? NSScreen.main else {
            window.center()
            return
        }
        let screenFrame = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = screenFrame.midX - frame.width / 2
        frame.origin.y = min(screenFrame.midY - frame.height / 2 + 60, screenFrame.maxY - frame.height - 20)
        window.setFrame(frame, display: false)
    }

    func close() {
        choiceMade = true
        window.close()
    }

    /// Called by the reply/acknowledge closures so a subsequent window-close
    /// (from the same button action) isn't double-counted as a dismiss.
    func markChoiceMade() {
        choiceMade = true
    }

    func windowWillClose(_ notification: Notification) {
        if !choiceMade {
            choiceMade = true
            onWindowClosedWithoutChoice()
        }
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }
}
