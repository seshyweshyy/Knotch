import AppKit
import SwiftUI

/// Optional hairline outline that appears around the notch only while the
/// content directly behind Knotch is dark (where the black shape would
/// otherwise vanish into it).
///
/// Luminance comes from the window server's own backdrop luma tracking on
/// `CABackdropLayer` — the same private mechanism AppKit's scroll pockets use
/// (`backdropLayer:didChangeLuma:`). It never touches ScreenCaptureKit or
/// screenshots and needs no Screen Recording permission. Every private piece
/// is availability-guarded; if anything is missing or a sample is
/// unavailable/protected, the outline simply stays hidden.
enum KnotchContrastOutline {
    enum Edge: CaseIterable, Hashable { case left, right, bottom, top }

    /// Thickness of each sampling strip, and its distance from the shape.
    /// Measured: strips thinner than ~16pt don't track (an 8pt strip reads a
    /// constant ~0.06 whatever is behind it), so 16pt is the floor. Each strip
    /// lives in its own click-through panel ordered BELOW Knotch's
    /// window, so it samples only what is behind Knotch — never the notch's
    /// own drop shadow — and can sit right against the shape.
    static let stripThickness: CGFloat = 16
    static let stripGap: CGFloat = 2
    /// Strips clipped (to the screen) below this in either dimension are dropped
    /// from the aggregate instead of being sampled — they wouldn't track anyway.
    static let minimumStripExtent: CGFloat = 16

    /// A backdrop with no filter stops reporting changes. A zero-strength
    /// brightness filter keeps luma updates flowing while the backdrop layer
    /// itself remains hidden in its separate sampler panel.
    static let sampleDepth: CGFloat = 8
    /// WindowServer clips this deliberately oversized region to the layer's
    /// actual bounds. Keeping it fixed preserves the initial luma registration
    /// while the notch animates and its strip windows resize.
    static let maximumSampleLength: CGFloat = 16_384
    static let lumaUpdateRate: Double = 0.1
    static let staleAfter: TimeInterval = 3.5
    /// Hold the last visible outline across a short sampler registration gap,
    /// but never keep it indefinitely if the window server stops responding.
    static let missingReadingGrace: TimeInterval = 1.5
    /// A bright reading must remain bright briefly before hiding the outline.
    static let brightConfirmation: TimeInterval = 0.3

    /// Require genuinely dark content: the old 0.40/0.48 pair also outlined
    /// midtone backgrounds. Keep a gap so small luma changes do not flicker.
    static let turnOnBelow: Double = 0.25
    static let turnOffAbove: Double = 0.33

    static let outlineWidth: CGFloat = 1.5
    static let outlineOpacity: Double = 0.15
    static let albumArtOutlineOpacity: Double = 0.35
    static let outlineFade: Animation = .easeInOut(duration: 0.5)

    static func isEligible(_ style: NotchAppearanceStyle) -> Bool {
        style != .fullLiquidGlass
    }

    static func isActive(enabled: Bool, style: NotchAppearanceStyle) -> Bool {
        enabled && isEligible(style) && isSamplingAvailable
    }

    static func nextDarkState(current: Bool, luma: Double) -> Bool {
        current ? luma < turnOffAbove : luma < turnOnBelow
    }

    private static let backdropLayerClass: CALayer.Type? = NSClassFromString("CABackdropLayer") as? CALayer.Type
    private static let filterClass: NSObject.Type? = NSClassFromString("CAFilter") as? NSObject.Type

    /// Private API — verified present, never assumed.
    static let isSamplingAvailable: Bool = {
        guard let layerClass = backdropLayerClass, let filterClass else { return false }
        let required = [
            "setTracksLuma:", "setTracksLumaWhileHidden:", "setLumaSubrect:",
            "setLumaUpdateRate:", "setWindowServerAware:",
        ]
        guard required.allSatisfy({ layerClass.instancesRespond(to: NSSelectorFromString($0)) }) else {
            return false
        }
        return filterClass.responds(to: NSSelectorFromString("filterWithType:"))
    }()

    fileprivate static func makeBackdropLayer() -> CALayer? {
        guard isSamplingAvailable else { return nil }
        return backdropLayerClass?.init()
    }

    fileprivate static func makeTrackingFilter() -> NSObject? {
        guard let filterClass,
              let unmanaged = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "colorBrightness"),
              let filter = unmanaged.takeUnretainedValue() as? NSObject else { return nil }
        filter.setValue(0.0, forKey: "inputAmount")
        return filter
    }
}

// MARK: - One sampling strip

/// A layer-backed view whose layer is a `CABackdropLayer` tracking luma. As the
/// layer's delegate it receives the private `backdropLayer:didChangeLuma:` and
/// `backdropLayer:didSampleProtectedLuma:` callbacks (type encodings verified
/// against AppKit's own implementations: `(id, double)` and `(id, BOOL)`).
private final class LumaStripView: NSView {
    enum Reading: Equatable {
        case unknown
        case protected
        case luma(Double)
    }

    private(set) var reading: Reading = .unknown
    private(set) var lastReadingAt: TimeInterval?
    private var isProtected = false
    private let edge: KnotchContrastOutline.Edge
    var onReadingChange: (() -> Void)?

    /// Whether this strip currently has usable on-window geometry and takes
    /// part in the aggregate. The view/window remain ordered on-screen; only
    /// the backdrop layer itself is hidden, with explicit hidden tracking.
    var isUsable = false

    init(edge: KnotchContrastOutline.Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        configureLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        KnotchContrastOutline.makeBackdropLayer() ?? CALayer()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func configureLayer() {
        guard let layer, KnotchContrastOutline.isSamplingAvailable else { return }
        // A visible backdrop in an external panel leaks its rectangular edge
        // through `destIn` compositing. In a separate ordered panel, a hidden
        // backdrop with tracksLumaWhileHidden still followed a black-to-white
        // window in a controlled macOS 27 probe. This was NOT true when the
        // layer lived inside Knotch's main SwiftUI window; keep it separate.
        layer.setValue(true, forKey: "tracksLumaWhileHidden")
        layer.isHidden = true
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(KnotchContrastOutline.lumaUpdateRate, forKey: "lumaUpdateRate")
        guard let filter = KnotchContrastOutline.makeTrackingFilter() else { return }
        layer.setValue([filter], forKey: "filters")
        // lumaSubrect uses layer coordinates, not normalized coordinates.
        // The far dimension is clipped to the window (verified with a split
        // black/white probe), so each region can stay fixed through resizing.
        let depth = KnotchContrastOutline.sampleDepth
        let length = KnotchContrastOutline.maximumSampleLength
        let thickness = KnotchContrastOutline.stripThickness
        let region: CGRect
        switch edge {
        case .left:
            region = CGRect(x: thickness - depth, y: 0, width: depth, height: length)
        case .right:
            region = CGRect(x: 0, y: 0, width: depth, height: length)
        case .bottom:
            region = CGRect(x: 0, y: thickness - depth, width: length, height: depth)
        case .top:
            region = CGRect(x: 0, y: 0, width: length, height: depth)
        }
        layer.setValue(NSValue(rect: region), forKey: "lumaSubrect")
        layer.setValue(true, forKey: "tracksLuma")
        isTracking = true
    }

    private(set) var isTracking = false

    /// Starts/stops tracking. Toggling `tracksLuma` on a layer that already
    /// failed to register does NOT revive it (measured: no callback ever
    /// arrives), so recovery is done by replacing the whole strip with a fresh
    /// layer instead — see ContrastOutlineSamplerView.rebuildStrips.
    func setActive(_ active: Bool) {
        guard KnotchContrastOutline.isSamplingAvailable, active != isTracking else { return }
        isTracking = active
        layer?.setValue(active, forKey: "tracksLuma")
        if !active { setReading(.unknown) }
    }

    /// Stops for good before the strip is discarded.
    func shutDown() {
        onReadingChange = nil
        setActive(false)
    }

    private func setReading(_ newValue: Reading) {
        lastReadingAt = newValue == .unknown ? nil : Date.timeIntervalSinceReferenceDate
        guard newValue != reading else { return }
        reading = newValue
        onReadingChange?()
    }

    @objc(backdropLayer:didChangeLuma:)
    func backdropLayer(_ layer: AnyObject, didChangeLuma luma: Double) {
        let value = min(max(luma, 0), 1)
        let apply: () -> Void = { [weak self] in
            guard let self, !self.isProtected else { return }
            self.setReading(.luma(value))
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    @objc(backdropLayer:didSampleProtectedLuma:)
    func backdropLayer(_ layer: AnyObject, didSampleProtectedLuma protected: Bool) {
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.isProtected = protected
            if protected {
                self.setReading(.protected)
            } else if self.reading == .protected {
                // Protection ended, but unchanged luma may not be re-reported.
                // The watchdog will request a fresh layer if it stays unknown.
                self.setReading(.unknown)
            }
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }
}

// MARK: - Strips around the shape

/// A borderless, click-through window holding one sampling strip, one level
/// below the notch window and (like it) a member of the notch's private
/// overlay space, so it shows up wherever the notch does.
private final class StripPanel: NSPanel {
    init(strip: LumaStripView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        contentView = strip
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Tracks up to four strips just outside Knotch's black shape and decides
/// visibility separately for each edge. This view's bounds ARE the shape's
/// frame; it draws nothing itself.
private final class ContrastOutlineSamplerView: NSView {
    struct Geometry: Equatable {
        var topCornerRadius: CGFloat
        var bottomCornerRadius: CGFloat
        var isIsland: Bool
    }

    typealias Edge = KnotchContrastOutline.Edge

    var geometry = Geometry(topCornerRadius: 6, bottomCornerRadius: 14, isIsland: false) {
        didSet { if geometry != oldValue { needsLayout = true } }
    }
    var onDarkChange: ((Set<Edge>) -> Void)?

    private var strips: [Edge: LumaStripView] = [:]
    private var panels: [Edge: StripPanel] = [:]
    private var desiredFrames: [Edge: CGRect] = [:]
    /// A pill near the screen edge has no room for a 16pt strip above it.
    /// In that case its top reading must not veto the entire outline.
    private var topHasSamplingArea = false
    private var placementWork: DispatchWorkItem?
    private var isShutDown = false
    private var darkEdges: Set<Edge> = []
    private var reportedDarkEdges: Set<Edge> = []
    private var missingSince: TimeInterval?
    private var brightSince: TimeInterval?
    private var decisionWork: DispatchWorkItem?
    private var decisionDeadline: TimeInterval?
    #if DEBUG
    private var lastDebugSummary = ""
    #endif
    private struct Observer {
        let center: NotificationCenter
        let token: NSObjectProtocol
        func remove() { center.removeObserver(token) }
    }
    private var observers: [Observer] = []
    private var retryWork: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for edge in Edge.allCases { installStrip(for: edge) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Strip / window lifecycle

    private func installStrip(for edge: Edge) {
        let strip = LumaStripView(edge: edge)
        strip.onReadingChange = { [weak self] in self?.reevaluate() }
        strips[edge] = strip
        panels[edge] = StripPanel(strip: strip)
    }

    /// Strip windows are independent of the notch window (no child-window
    /// relationship, nothing changed on it): one level below it, in the same
    /// overlay space, so they sample only what is behind Knotch.
    private func attach(_ panel: StripPanel) {
        guard let window, !panel.isVisible else { return }
        panel.level = NSWindow.Level(rawValue: window.level.rawValue - 1)
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
        panel.orderFrontRegardless()
    }

    private func detach(_ panel: StripPanel) {
        NotchSpaceManager.shared.notchSpace.windows.remove(panel)
        panel.orderOut(nil)
    }

    private func discard(_ edge: Edge) {
        strips[edge]?.shutDown()
        if let panel = panels[edge] {
            detach(panel)
            panel.close()
        }
        strips[edge] = nil
        panels[edge] = nil
        desiredFrames[edge] = nil
    }

    /// Replaces strips (and their windows) with brand-new ones. A layer that
    /// failed to register with the window server (launch race) or lost its
    /// tracking (screenshot, Space/display change) can't be revived by
    /// toggling, but a fresh one tracks normally.
    private func rebuildStrips(_ edges: [Edge] = Edge.allCases) {
        guard !isShutDown else { return }
        for edge in edges {
            discard(edge)
            installStrip(for: edge)
        }
        needsLayout = true
        reevaluate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { $0.remove() }
        observers = []

        guard let window else {
            stopSampling()
            return
        }
        // Anything that can drop or invalidate tracking → fresh strips.
        let rebuild: (Notification) -> Void = { [weak self] _ in self?.rebuildStrips() }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(Observer(center: center, token: center.addObserver(forName: name, object: window, queue: .main, using: rebuild)))
        }
        observers.append(Observer(center: center, token: center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: rebuild)))
        observers.append(Observer(center: workspace, token: workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: rebuild)))
        observers.append(Observer(center: workspace, token: workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: rebuild)))
        observers.append(Observer(center: workspace, token: workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: rebuild)))
        // Created before the window was on screen? Start over now that it is.
        rebuildStrips()
    }

    /// Called when SwiftUI tears the view down (toggle off, style change,
    /// display/window removal): every strip window is removed with it.
    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        observers.forEach { $0.remove() }
        observers = []
        retryWork?.cancel()
        retryWork = nil
        cancelDecision()
        placementWork?.cancel()
        placementWork = nil
        stopSampling()
        for edge in Edge.allCases { discard(edge) }
    }

    private func stopSampling() {
        cancelDecision()
        missingSince = nil
        brightSince = nil
        darkEdges = []
        topHasSamplingArea = false
        for edge in Edge.allCases {
            strips[edge]?.shutDown()
            strips[edge]?.isUsable = false
            if let panel = panels[edge] { detach(panel) }
        }
        desiredFrames = [:]
        reportVisibility([])
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        guard !isShutDown, let window, bounds.width > 0, bounds.height > 0 else { return }
        let shape = bounds
        let screenFrame = (window.screen ?? NSScreen.main)?.frame ?? .infinite

        let thickness = KnotchContrastOutline.stripThickness
        let gap = KnotchContrastOutline.stripGap
        let minExtent = KnotchContrastOutline.minimumStripExtent

        // The notch's straight side walls sit inset by the top radius from its
        // frame (the concave corners sweep in to them), and its bottom edge
        // runs between the two bottom curves; the floating pill is a plain
        // rounded rect. Strips are centred on those straight runs.
        let radius = min(geometry.bottomCornerRadius, min(shape.width, shape.height) / 2)
        let wallInset = geometry.isIsland ? 0 : geometry.topCornerRadius
        let sideY = geometry.isIsland ? radius : geometry.topCornerRadius
        let sideBottomY = geometry.isIsland ? radius : geometry.bottomCornerRadius
        let bottomInset = geometry.isIsland ? radius : geometry.topCornerRadius + geometry.bottomCornerRadius

        // Bounds can invert when the shape is short relative to its radii
        // (e.g. a 32pt pill), so this works from a midpoint and a clamped
        // length rather than building a range.
        func centred(from low: CGFloat, to high: CGFloat) -> (start: CGFloat, length: CGFloat) {
            let length = max(high - low, minExtent * 2)
            return ((low + high) / 2 - length / 2, length)
        }

        let side = centred(from: shape.minY + sideY, to: shape.maxY - sideBottomY)
        let horizontal = centred(from: shape.minX + bottomInset, to: shape.maxX - bottomInset)

        var wanted: [Edge: CGRect] = [
            .left: CGRect(
                x: shape.minX + wallInset - gap - thickness, y: side.start,
                width: thickness, height: side.length),
            .right: CGRect(
                x: shape.maxX - wallInset + gap, y: side.start,
                width: thickness, height: side.length),
            .bottom: CGRect(
                x: horizontal.start, y: shape.maxY + gap,
                width: horizontal.length, height: thickness),
        ]
        // The hardware notch is flush with the screen's top edge, so there's
        // nothing above it to sample.
        if geometry.isIsland {
            wanted[.top] = CGRect(
                x: horizontal.start, y: shape.minY - gap - thickness,
                width: horizontal.length, height: thickness)
        }

        for edge in Edge.allCases {
            guard var strip = strips[edge], var panel = panels[edge] else { continue }
            // Screen coordinates, trimmed to the display (e.g. above a pill
            // that sits 1pt from the top edge there's nothing to sample).
            let screenRect = wanted[edge].map { window.convertToScreen(convert($0, to: nil)).intersection(screenFrame) }
            // Tolerance: geometry round trips can return 15.999… for a 16pt strip.
            let hasSamplingArea = screenRect.map {
                !$0.isNull && $0.width >= minExtent - 0.5 && $0.height >= minExtent - 0.5
            } ?? false
            if edge == .top { topHasSamplingArea = hasSamplingArea }
            if hasSamplingArea, let screenRect {
                if !strip.isTracking {
                    // An off/on toggle cannot reliably re-register a backdrop
                    // that was clipped offscreen. Reattach a fresh layer.
                    discard(edge)
                    installStrip(for: edge)
                    guard let freshStrip = strips[edge], let freshPanel = panels[edge] else { continue }
                    strip = freshStrip
                    panel = freshPanel
                }
                strip.isUsable = true
                desiredFrames[edge] = screenRect
            } else {
                strip.isUsable = false
                desiredFrames[edge] = nil
                strip.setActive(false)
                detach(panel)
            }
        }
        schedulePlacement()
        reevaluate()
    }

    /// Moving windows is a window-server round trip; during the notch's spring
    /// layout runs every frame, so placement is throttled to ~25 Hz.
    private func schedulePlacement() {
        guard placementWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.placementWork = nil
            for (edge, rect) in self.desiredFrames {
                guard let panel = self.panels[edge] else { continue }
                if abs(panel.frame.minX - rect.minX) > 0.5 || abs(panel.frame.minY - rect.minY) > 0.5
                    || abs(panel.frame.width - rect.width) > 0.5 || abs(panel.frame.height - rect.height) > 0.5 {
                    panel.setFrame(rect, display: false)
                }
                // WindowServer must see a nonzero frame when the backdrop is
                // ordered in; a zero-size initial window can fail to register.
                self.attach(panel)
            }
            self.reevaluate()
        }
        placementWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    /// Continue checking even after the first reading. WindowServer can stop
    /// delivering updates while leaving the last value in place, which used
    /// to keep an outdated outline on or off indefinitely.
    private func scheduleRetry() {
        guard !isShutDown, retryWork == nil, let window, window.isVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            let now = Date.timeIntervalSinceReferenceDate
            let stuck = Edge.allCases.filter { edge in
                guard let strip = self.strips[edge], strip.isUsable else { return false }
                if case .protected = strip.reading { return false }
                if let last = strip.lastReadingAt { return now - last > KnotchContrastOutline.staleAfter }
                return true
            }
            #if DEBUG
            if !stuck.isEmpty {
                print("KnotchContrastOutline: rebuilding missing/stale strips \(stuck)")
            }
            #endif
            if !stuck.isEmpty { self.rebuildStrips(stuck) } else { self.reevaluate() }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func cancelDecision() {
        decisionWork?.cancel()
        decisionWork = nil
        decisionDeadline = nil
    }

    private func scheduleDecision(at deadline: TimeInterval) {
        if let decisionDeadline, abs(decisionDeadline - deadline) < 0.001 { return }
        cancelDecision()
        decisionDeadline = deadline
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.decisionWork = nil
            self.decisionDeadline = nil
            self.reevaluate()
        }
        decisionWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline - Date.timeIntervalSinceReferenceDate),
            execute: work
        )
    }

    private func reportVisibility(_ edges: Set<Edge>) {
        guard edges != reportedDarkEdges else { return }
        reportedDarkEdges = edges
        #if DEBUG
        print("KnotchContrastOutline: darkEdges=\(darkEdges), visibleEdges=\(edges)")
        #endif
        onDarkChange?(edges)
    }

    /// Keep hysteresis for each edge, but only draw a complete contour when
    /// every required edge is dark. Preserve the last visible contour during
    /// a short read gap, and confirm bright content before hiding it.
    private func reevaluate() {
        let now = Date.timeIntervalSinceReferenceDate
        // The default pill is only 1pt below the screen edge. Its top strip
        // is entirely offscreen, so use its two sides and bottom. Once a pill
        // is floated far enough down, the top strip becomes required too.
        let required: [Edge] = geometry.isIsland && topHasSamplingArea
            ? Edge.allCases : [.left, .right, .bottom]
        var next = darkEdges
        var hasMissing = false
        var hasBright = false
        var hasProtected = false
        for edge in required {
            guard let strip = strips[edge], strip.isUsable,
                  let last = strip.lastReadingAt,
                  now - last <= KnotchContrastOutline.staleAfter else {
                hasMissing = true
                continue
            }
            switch strip.reading {
            case .luma(let value):
                if KnotchContrastOutline.nextDarkState(current: darkEdges.contains(edge), luma: value) {
                    next.insert(edge)
                } else {
                    next.remove(edge)
                    hasBright = true
                }
            case .protected:
                next.remove(edge)
                hasProtected = true
            case .unknown:
                hasMissing = true
            }
        }
        scheduleRetry()

        #if DEBUG
        let readings = strips.keys.sorted { "\($0)" < "\($1)" }.map { edge -> String in
            let strip = strips[edge]!
            return "\(edge)=\(strip.isUsable ? "\(strip.reading)" : "unusable")"
        }.joined(separator: " | ")
        let summary = "required=\(required) | \(readings)"
        if summary != lastDebugSummary {
            lastDebugSummary = summary
            print("KnotchContrastOutline: \(summary)")
        }
        #endif

        if hasProtected {
            darkEdges = next
            missingSince = nil
            brightSince = nil
            cancelDecision()
            reportVisibility([])
        } else if hasBright {
            missingSince = nil
            guard !reportedDarkEdges.isEmpty else {
                darkEdges = next
                brightSince = nil
                cancelDecision()
                return
            }
            if brightSince == nil { brightSince = now }
            let deadline = brightSince! + KnotchContrastOutline.brightConfirmation
            if now >= deadline {
                darkEdges = next
                cancelDecision()
                reportVisibility([])
            } else {
                scheduleDecision(at: deadline)
            }
        } else if hasMissing {
            darkEdges = next
            brightSince = nil
            guard !reportedDarkEdges.isEmpty else {
                missingSince = nil
                cancelDecision()
                return
            }
            if missingSince == nil { missingSince = now }
            let deadline = missingSince! + KnotchContrastOutline.missingReadingGrace
            if now >= deadline {
                cancelDecision()
                reportVisibility([])
            } else {
                scheduleDecision(at: deadline)
            }
        } else {
            darkEdges = next
            missingSince = nil
            brightSince = nil
            cancelDecision()
            reportVisibility(Set(required))
        }
    }
}

// MARK: - SwiftUI

private struct KnotchContrastOutlineSampler: NSViewRepresentable {
    var shape: NotchOuterShape
    var onDarkChange: (Set<KnotchContrastOutline.Edge>) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ContrastOutlineSamplerView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ContrastOutlineSamplerView else { return }
        apply(to: view)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let view = nsView as? ContrastOutlineSamplerView else { return }
        view.shutDown()
    }

    private func apply(to view: ContrastOutlineSamplerView) {
        view.onDarkChange = onDarkChange
        view.geometry = .init(
            topCornerRadius: shape.topCornerRadius,
            bottomCornerRadius: shape.bottomCornerRadius,
            isIsland: shape.isIsland
        )
    }
}

/// The outline itself: Knotch's own animated `NotchOuterShape`, stroked and
/// then masked to only the part OUTSIDE the shape. The stroke used to straddle
/// the path, but the hardware notch's walls sit within a couple of points of
/// the physical cutout, which hides the inner half — so the line looked
/// patchy along the sides yet fine along the bottom and on the pill. Drawing
/// only outside keeps the ring the same on every edge. This is one continuous
/// stroke: splitting it into independent edge masks left a stray bottom line
/// whenever its luminance differed from the side readings. The hardware notch
/// fades out at the very top; the floating pill keeps its full perimeter.
private struct KnotchContrastOutlineStroke: View {
    var shape: NotchOuterShape
    var visibleEdges: Set<KnotchContrastOutline.Edge>
    var color: Color
    var opacity: Double
    var forceVisible: Bool
    @State private var displayedVisibility: Double = 0

    // Room for the outer half of the stroke past the shape's frame.
    private static let overhang: CGFloat = 8
    private static let topFade: CGFloat = 3

    private var shouldShow: Bool {
        forceVisible || !visibleEdges.isEmpty
    }

    var body: some View {
        shape
            .stroke(color.opacity(opacity), lineWidth: KnotchContrastOutline.outlineWidth * 2)
            .mask { outsideMask }
            .mask { topMask }
            // Fade only the alpha. An animation modifier on this shape also
            // captures notchSize/corner-radius changes when opening, causing
            // the outline to take a delayed, curved route around the panel.
            .opacity(displayedVisibility)
            .onAppear {
                displayedVisibility = shouldShow ? 1 : 0
            }
            .onChange(of: shouldShow) { _, isVisible in
                withAnimation(KnotchContrastOutline.outlineFade) {
                    displayedVisibility = isVisible ? 1 : 0
                }
            }
            .allowsHitTesting(false)
    }

    private var outsideMask: some View {
        ZStack {
            Rectangle().padding(-Self.overhang)
            shape.fill(.black).blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    @ViewBuilder
    private var topMask: some View {
        if shape.isIsland {
            Rectangle().padding(-Self.overhang)
        } else {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.topFade)
                Rectangle()
            }
            .padding([.horizontal, .bottom], -Self.overhang)
        }
    }
}

extension View {
    /// The stroke stays mounted while the feature is enabled, allowing it to
    /// fade out after an activity ends. Sampling stops as soon as it is idle.
    func knotchContrastOutline(
        isEnabled: Bool,
        isActivityActive: Bool,
        visibleEdges: Binding<Set<KnotchContrastOutline.Edge>>,
        shape: NotchOuterShape,
        color: Color,
        opacity: Double,
        forceVisible: Bool
    ) -> some View {
        let isSampling = isEnabled && isActivityActive
        return self
            .background {
                if isSampling {
                    KnotchContrastOutlineSampler(shape: shape) { edges in
                        visibleEdges.wrappedValue = edges
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if isEnabled {
                    KnotchContrastOutlineStroke(
                        shape: shape,
                        visibleEdges: visibleEdges.wrappedValue,
                        color: color,
                        opacity: opacity,
                        forceVisible: forceVisible && isActivityActive
                    )
                }
            }
            .onChange(of: isSampling) { _, sampling in
                if !sampling {
                    visibleEdges.wrappedValue = []
                }
            }
    }
}
