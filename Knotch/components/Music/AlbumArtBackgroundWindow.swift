//
//  AlbumArtBackgroundWindow.swift
//  Knotch
//

import AppKit
import SwiftUI
import Combine
import SkyLightWindow
import IOKit.ps

// MARK: - Background Window (level 300)

class AlbumArtBackgroundWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        hasShadow = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        sharingType = .none
    }
}

// MARK: - Clock Overlay Window (SkyLight level 400)

class LockClockOverlayWindow: BoringNotchSkyLightWindow {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isMovable = false
        sharingType = .none
    }
}

// MARK: - Background View

private struct AlbumArtBackgroundView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var colors: [Color] = [.black, .gray, .black]

    var body: some View {
        GeometryReader { _ in
            LinearGradient(
                stops: [
                    .init(color: colors[0], location: 0),
                    .init(color: colors[safe: 1, fallback: colors[0]], location: 0.5),
                    .init(color: colors[safe: 2, fallback: colors[0]], location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(Color.white.opacity(0.02))
            .ignoresSafeArea()
            .overlay(
                RadialGradient(
                    colors: [colors[0].opacity(0.3), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 400
                )
            )
        }
        .onChange(of: musicManager.artFlipSignal) { _, signal in
            signal.art.dominantColors(count: 3) { nsColors in
                withAnimation(.easeInOut(duration: 0.8)) {
                    colors = nsColors.map { Color(nsColor: $0).saturated(by: 1.4).darkened(by: 0.2) }
                }
            }
        }
        .onAppear {
            musicManager.albumArt.dominantColors(count: 3) { nsColors in
                withAnimation(.easeInOut(duration: 0.8)) {
                    colors = nsColors.map { Color(nsColor: $0).saturated(by: 1.4).darkened(by: 0.2) }
                }
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let albumArtBackgroundShouldShow = Notification.Name("albumArtBackgroundShouldShow")
    static let albumArtBackgroundShouldHide = Notification.Name("albumArtBackgroundShouldHide")
    static let lockScreenProfileShouldHide  = Notification.Name("lockScreenProfileShouldHide")
    static let lockScreenProfileShouldShow  = Notification.Name("lockScreenProfileShouldShow")
}

// MARK: - Controller

class AlbumArtBackgroundWindowController {
    static let shared = AlbumArtBackgroundWindowController()

    // Background gradient window
    private var backgroundWindow: AlbumArtBackgroundWindow?
    private var backgroundSpace: Int32 = 0

    // Lock screen overlay window
    private var clockWindow: LockClockOverlayWindow?
    private var bigTimeVC: NSViewController?
    private var dateVC: NSViewController?
    private var clockTimer: Timer?
    private var statusVC: NSViewController?
    private var batteryPercentLabel: NSTextField?
    private var clockLayoutConstraints: [NSLayoutConstraint] = []

    typealias F_SLSMainConnectionID = @convention(c) () -> Int32
    typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private init() {
        setupBackgroundSpace()
        loadLUIClockControllers()
    }

    // MARK: - Setup

    private func setupBackgroundSpace() {
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        let SLSMainConnectionID = unsafeBitCast(dlsym(handler, "SLSMainConnectionID"), to: F_SLSMainConnectionID.self)
        let SLSSpaceCreate = unsafeBitCast(dlsym(handler, "SLSSpaceCreate"), to: F_SLSSpaceCreate.self)
        let SLSSpaceSetAbsoluteLevel = unsafeBitCast(dlsym(handler, "SLSSpaceSetAbsoluteLevel"), to: F_SLSSpaceSetAbsoluteLevel.self)
        let SLSShowSpaces = unsafeBitCast(dlsym(handler, "SLSShowSpaces"), to: F_SLSShowSpaces.self)

        let connection = SLSMainConnectionID()
        let space = SLSSpaceCreate(connection, 1, 0)
        _ = SLSSpaceSetAbsoluteLevel(connection, space, 300)
        _ = SLSShowSpaces(connection, [space] as CFArray)
        backgroundSpace = space
    }

    private func loadLUIClockControllers() {
        let bundleURL = URL(fileURLWithPath: "/System/Library/CoreServices/SecurityAgentPlugins/loginwindow.bundle")
        guard let bundle = Bundle(url: bundleURL), bundle.load() else {
            return
        }
        
        if let cls = NSClassFromString("LUI2BigTimeViewController") as? NSObject.Type {
            let vc = cls.init() as? NSViewController
            vc?.perform(NSSelectorFromString("viewDidLoad"))
            vc?.perform(NSSelectorFromString("_updateTime"))  // populate layers first
            bigTimeVC = vc
        }

        if let cls = NSClassFromString("LUI2DateViewController") as? NSObject.Type {
            let vc = cls.init() as? NSViewController
            vc?.perform(NSSelectorFromString("viewDidLoad"))
            dateVC = vc
        }
        
        if let cls = NSClassFromString("LUI2StatusViewController") as? NSObject.Type {
            let vc = cls.init() as? NSViewController
            vc?.perform(NSSelectorFromString("viewDidLoad"))
            vc?.perform(NSSelectorFromString("resume"))
            statusVC = vc
            
            let batterySelector = NSSelectorFromString("batteryViewController")
            if let batteryVC = vc?.perform(batterySelector)?.takeUnretainedValue() as? NSViewController {
                batteryVC.perform(NSSelectorFromString("viewDidLoad"))
                batteryVC.perform(NSSelectorFromString("resume"))
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    batteryVC.perform(NSSelectorFromString("_updateViews"))
                    if let textField = batteryVC.view.subviews.first(where: { $0 is NSTextField }) as? NSTextField {
                        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
                        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
                        if let source = sources.first {
                            let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as! [String: Any]
                            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
                                textField.stringValue = "\(capacity)%"
                            }
                        }
                    }
                }
            }
        }

        // Clock settings intentionally omitted — LUI2BigTimeViewController uses system defaults
    }

    // MARK: - Public API

    func prepare(on screen: NSScreen) {
        // Background window
        if backgroundWindow == nil {
            let win = AlbumArtBackgroundWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.contentView = NSHostingView(rootView: AlbumArtBackgroundView())
            backgroundWindow = win
        }
        backgroundWindow?.setFrame(screen.frame, display: false)

        // Clock overlay window
        if clockWindow == nil {
            let win = LockClockOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.contentView = NSView(frame: screen.frame)
            win.contentView?.wantsLayer = true
            clockWindow = win
        }
        clockWindow?.setFrame(screen.frame, display: false)
        layoutClockViews(for: screen)
    }

    private func layoutClockViews(for screen: NSScreen) {
        guard let contentView = clockWindow?.contentView else { return }

        let screenHeight = screen.frame.height
        let screenWidth = screen.frame.width

        // Deactivate previously installed constraints (they live on the parent/contentView)
        NSLayoutConstraint.deactivate(clockLayoutConstraints)
        clockLayoutConstraints = []

        var newConstraints: [NSLayoutConstraint] = []

        if let dateView = dateVC?.view {
            dateView.translatesAutoresizingMaskIntoConstraints = false
            if dateView.superview == nil {
                contentView.addSubview(dateView)
            }
            newConstraints += [
                dateView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                dateView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: screenHeight * 0.09),
                dateView.widthAnchor.constraint(equalToConstant: screenWidth * 0.6),
                dateView.heightAnchor.constraint(equalToConstant: 30),
            ]
        }

        if let clockView = bigTimeVC?.view {
            clockView.translatesAutoresizingMaskIntoConstraints = false
            if clockView.superview == nil {
                contentView.addSubview(clockView)
            }
            newConstraints += [
                clockView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                clockView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: screenHeight * 0.105),
                clockView.widthAnchor.constraint(equalToConstant: screenWidth * 0.7),
                clockView.heightAnchor.constraint(equalToConstant: 160),
            ]
        }

        if let statusView = statusVC?.view {
            statusView.translatesAutoresizingMaskIntoConstraints = false
            if statusView.superview == nil {
                contentView.addSubview(statusView)
            }
            newConstraints += [
                statusView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                statusView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1.1),
                statusView.heightAnchor.constraint(equalToConstant: 22),
            ]
        }

        // Battery label
        if batteryPercentLabel == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.isBezeled = false
            label.drawsBackground = false
            contentView.addSubview(label)
            batteryPercentLabel = label

            if let statusView = statusVC?.view {
                newConstraints += [
                    label.trailingAnchor.constraint(equalTo: statusView.leadingAnchor, constant: 0),
                    label.centerYAnchor.constraint(equalTo: statusView.centerYAnchor, constant: 3),
                ]
            } else {
                newConstraints += [
                    label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
                    label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
                ]
            }
        }

        NSLayoutConstraint.activate(newConstraints)
        clockLayoutConstraints = newConstraints
        updateBatteryLabel()
    }
    
    private func updateBatteryLabel() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        if let source = sources.first {
            let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as! [String: Any]
            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
                batteryPercentLabel?.stringValue = "\(capacity)%"
            }
        }
    }

    func show() {
        guard let bgWin = backgroundWindow, let clkWin = clockWindow else { return }
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        let SLSMainConnectionID = unsafeBitCast(dlsym(handler, "SLSMainConnectionID"), to: F_SLSMainConnectionID.self)
        let SLSSpaceAddWindowsAndRemoveFromSpaces = unsafeBitCast(dlsym(handler, "SLSSpaceAddWindowsAndRemoveFromSpaces"), to: F_SLSSpaceAddWindowsAndRemoveFromSpaces.self)

        let connection = SLSMainConnectionID()

        bgWin.alphaValue = 0
        bgWin.orderFrontRegardless()
        _ = SLSSpaceAddWindowsAndRemoveFromSpaces(connection, SkyLightOperator.shared.space, [bgWin.windowNumber] as CFArray, 7)
        bgWin.order(.below, relativeTo: clkWin.windowNumber)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bgWin.animator().alphaValue = 1
            }
        }

        // Show clock overlay via SkyLight (level 400)
        clkWin.alphaValue = 0
        clkWin.enableSkyLight()
        clkWin.orderFrontRegardless()
        
        bigTimeVC?.perform(NSSelectorFromString("_updateTime"))
        suppressDuplicateBackingLayers()

        // Start clock timer
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.bigTimeVC?.perform(NSSelectorFromString("_updateTime"))
            self?.updateBatteryLabel()
            self?.suppressDuplicateBackingLayers()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clkWin.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let bgWin = backgroundWindow, let clkWin = clockWindow else { return }

        clockTimer?.invalidate()
        clockTimer = nil

        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        let SLSMainConnectionID = unsafeBitCast(dlsym(handler, "SLSMainConnectionID"), to: F_SLSMainConnectionID.self)
        let SLSRemoveWindowsFromSpaces = unsafeBitCast(dlsym(handler, "SLSRemoveWindowsFromSpaces"), to: F_SLSRemoveWindowsFromSpaces.self)

        let connection = SLSMainConnectionID()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            bgWin.animator().alphaValue = 0
            clkWin.animator().alphaValue = 0
        }, completionHandler: {
            _ = SLSRemoveWindowsFromSpaces(connection, [bgWin.windowNumber] as CFArray, [SkyLightOperator.shared.space] as CFArray)
            bgWin.orderOut(nil)
            clkWin.disableSkyLight()
            clkWin.orderOut(nil)
        })
    }

    func updateScreen(_ screen: NSScreen) {
        backgroundWindow?.setFrame(screen.frame, display: true)
        clockWindow?.setFrame(screen.frame, display: true)
        layoutClockViews(for: screen)
    }
    
    private func suppressDuplicateBackingLayers() {
        guard let rootLayer = bigTimeVC?.view.layer else { return }
        let backingLayers = rootLayer.sublayers ?? []
        for (i, layer) in backingLayers.enumerated() {
            layer.isHidden = i < backingLayers.count - 1
        }
    }
}

// MARK: - Array safe subscript
private extension Array {
    subscript(safe index: Int, fallback fallback: Element) -> Element {
        indices.contains(index) ? self[index] : fallback
    }
}

// MARK: - Color helpers
private extension Color {
    func saturated(by factor: CGFloat) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s * factor, 1), brightness: b, opacity: a)
    }

    func darkened(by amount: CGFloat) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: s, brightness: max(b - amount, 0), opacity: a)
    }
}
