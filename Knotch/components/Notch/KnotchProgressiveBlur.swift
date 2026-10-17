import AppKit
import SwiftUI

/// Soft, iOS-style blur halo just OUTSIDE the notch's edges.
///
/// Mirrors what was found in Alcove (see alcove-research/REPORT.md §4a): one
/// `CABackdropLayer` carrying one private `variableBlur` `CAFilter` whose
/// `inputMaskImage` is a small, low-resolution ring-shaped mask that is only
/// regenerated when the halo's size changes. The layer lives in a separate
/// click-through panel one level below the notch window.
///
/// Cost model:
/// - one filter, created once; the mask is tiny (a quarter of the halo's
///   point size) so regenerating it as the notch springs is negligible;
/// - the panel only moves/resizes when the notch *window* does, never per
///   frame — the backdrop is just a subview whose frame follows the shape;
/// - the panel is taken off screen shortly after the effect fades out;
/// - disabled entirely in Low Power Mode.
///
/// Every private piece (CABackdropLayer / CAFilter and their KVC keys) is
/// availability-guarded, like KnotchContrastOutline; if anything is missing
/// the effect stays off. NOT yet verified on screen: the mask is assumed to be
/// stretched over the layer's bounds and read as alpha (RGB is set equal to
/// alpha as well, to cover luminance).
enum KnotchProgressiveBlur {
    /// How far the halo reaches beyond the shape's edge.
    static let outset: CGFloat = 280
    /// `inputRadius` of the variable blur at full mask strength. Alcove's own
    /// value was not recovered; 12 smeared content into unreadable bars, so this
    /// starts lower. Tune by eye.
    static let blurRadius: CGFloat = 3.5
    /// Alcove sets `bleedAmount = 12.0` on its backdrop layer.
    static let bleedAmount: Double = 12
    /// Mask is rendered at this fraction of the halo's point size.
    static let maskScale: CGFloat = 0.5
    static let fadeDuration: TimeInterval = 0.35

    static func isActive(enabled: Bool, lowPowerMode: Bool) -> Bool {
        enabled && isAvailable && !lowPowerMode
    }

    private static let backdropLayerClass: CALayer.Type? = NSClassFromString("CABackdropLayer") as? CALayer.Type
    private static let filterClass: NSObject.Type? = NSClassFromString("CAFilter") as? NSObject.Type

    static let isAvailable: Bool = {
        guard backdropLayerClass != nil, let filterClass,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")) else { return false }
        return makeBlurFilter() != nil
    }()

    /// KVC on a missing key throws, so every set is guarded by its setter.
    private static func set(_ object: NSObject, _ key: String, _ value: Any) {
        let setter = NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
        guard object.responds(to: setter) else { return }
        object.setValue(value, forKey: key)
    }

    fileprivate static func makeBackdropLayer() -> CALayer? {
        guard let layer = backdropLayerClass?.init() else { return nil }
        layer.masksToBounds = true
        set(layer, "windowServerAware", true)
        set(layer, "allowsInPlaceFiltering", true)
        set(layer, "allowsGroupBlending", true)
        set(layer, "allowsGroupOpacity", true)
        set(layer, "allowsEdgeAntialiasing", false)
        set(layer, "disablesOccludedBackdropBlurs", true)
        set(layer, "ignoresOffscreenGroups", true)
        set(layer, "bleedAmount", bleedAmount)
        return layer
    }

    fileprivate static func makeBlurFilter() -> NSObject? {
        guard let filterClass,
              let unmanaged = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur"),
              let filter = unmanaged.takeUnretainedValue() as? NSObject else { return nil }
        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue(blurRadius, forKey: "inputRadius")
        return filter
    }

    /// `cutOut` zeroes the mask inside the shape (for translucent glass styles).
    /// Core Graphics rasterizes the exact animated shape and its soft shadow,
    /// avoiding per-pixel Swift work while preserving the matching corners.
    fileprivate static func makeMask(size: CGSize, shape: NotchOuterShape, cutOut: Bool) -> CGImage? {
        let width = max(2, Int((size.width * maskScale).rounded(.up)))
        let height = max(2, Int((size.height * maskScale).rounded(.up)))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let scaledOutset = outset * maskScale
        let shapeRect = CGRect(
            x: scaledOutset,
            y: scaledOutset,
            width: max(0, CGFloat(width) - 2 * scaledOutset),
            height: max(0, CGFloat(height) - 2 * scaledOutset)
        )
        guard shapeRect.width > 0, shapeRect.height > 0 else { return nil }

        let scaledShape = NotchOuterShape(
            topCornerRadius: shape.topCornerRadius * maskScale,
            bottomCornerRadius: shape.bottomCornerRadius * maskScale,
            isIsland: shape.isIsland
        )
        let path = scaledShape.path(in: shapeRect).cgPath
        let white = CGColor(gray: 1, alpha: 1)

        // CAFilter interprets the image in layer coordinates while the bitmap
        // context writes its rows in the opposite vertical direction.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setShadow(
            offset: .zero,
            blur: outset * 0.72 * maskScale,
            color: white
        )
        ctx.setFillColor(white)
        ctx.addPath(path)
        ctx.fillPath()

        if cutOut {
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setBlendMode(.clear)
            ctx.addPath(path)
            ctx.fillPath()
        }

        return ctx.makeImage()
    }
}

// MARK: - Panel

private final class BlurBackdropView: NSView {
    override func makeBackingLayer() -> CALayer {
        KnotchProgressiveBlur.makeBackdropLayer() ?? CALayer()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Click-through, one level below the notch window, in the notch's overlay
/// space so it follows the notch onto every Space (and the lock screen).
private final class BlurPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Unlike the notch itself, this private backdrop layer must disappear
        // during Mission Control or its snapshot becomes an opaque rectangle.
        collectionBehavior = [.fullScreenAuxiliary, .transient, .canJoinAllSpaces, .ignoresCycle]
        contentView = NSView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Bounds of this view ARE the notch shape's frame; it draws nothing itself.
private final class ProgressiveBlurHostView: NSView {
    var isActive = false {
        didSet { if isActive != oldValue { activityChanged() } }
    }
    var topCornerRadius: CGFloat = 0 {
        didSet { if abs(topCornerRadius - oldValue) >= 0.5 { needsLayout = true } }
    }
    var bottomCornerRadius: CGFloat = 0 {
        didSet { if abs(bottomCornerRadius - oldValue) >= 0.5 { needsLayout = true } }
    }
    var isIsland = false {
        didSet { if isIsland != oldValue { needsLayout = true } }
    }
    var cutsOutShape = false {
        didSet { if cutsOutShape != oldValue { needsLayout = true } }
    }

    private let panel = BlurPanel()
    private let backdropView = BlurBackdropView()
    private var filter: NSObject?
    private var maskSize: CGSize = .zero
    private var maskTopCornerRadius: CGFloat = -1
    private var maskBottomCornerRadius: CGFloat = -1
    private var maskIsIsland = false
    private var maskCutOut = false
    private var isShutDown = false
    private var observers: [NSObjectProtocol] = []
    private var detachWork: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        guard KnotchProgressiveBlur.isAvailable else { return }
        backdropView.wantsLayer = true
        backdropView.alphaValue = 0
        filter = KnotchProgressiveBlur.makeBlurFilter()
        panel.contentView?.addSubview(backdropView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else {
            detach()
            return
        }
        let reposition: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main, using: reposition))
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reposition))
        if isActive { activityChanged() }
        needsLayout = true
    }

    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        detachWork?.cancel()
        detach()
        panel.close()
    }

    private func attach() {
        guard !isShutDown, filter != nil, let window else { return }
        detachWork?.cancel()
        detachWork = nil
        panel.level = NSWindow.Level(rawValue: window.level.rawValue - 1)
        if !panel.isVisible {
            placePanel()
            NotchSpaceManager.shared.notchSpace.windows.insert(panel)
            panel.orderFrontRegardless()
        }
    }

    private func detach() {
        NotchSpaceManager.shared.notchSpace.windows.remove(panel)
        panel.orderOut(nil)
    }

    private func activityChanged() {
        guard !isShutDown, filter != nil else { return }
        if isActive {
            attach()
            layoutBackdrop()
            fade(to: 1)
        } else {
            fade(to: 0)
            // Stop the window server blurring once the fade has finished.
            detachWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isActive else { return }
                self.detach()
            }
            detachWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + KnotchProgressiveBlur.fadeDuration + 0.1, execute: work)
        }
    }

    private func fade(to value: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = KnotchProgressiveBlur.fadeDuration
            backdropView.animator().alphaValue = value
        }
    }

    // MARK: Geometry

    /// Fixed to the notch window plus the halo reach: only changes when the
    /// window moves, never during the notch's spring.
    private func placePanel() {
        guard let window else { return }
        let reach = KnotchProgressiveBlur.outset
        let screenFrame = (window.screen ?? NSScreen.main)?.frame ?? .infinite
        let wanted = window.frame.insetBy(dx: -reach, dy: -reach).intersection(screenFrame)
        guard !wanted.isNull, wanted.width > 0, wanted.height > 0 else { return }
        let current = panel.frame
        if abs(current.minX - wanted.minX) > 0.5 || abs(current.minY - wanted.minY) > 0.5
            || abs(current.width - wanted.width) > 0.5 || abs(current.height - wanted.height) > 0.5 {
            panel.setFrame(wanted, display: false)
        }
    }

    override func layout() {
        super.layout()
        guard !isShutDown, isActive else { return }
        placePanel()
        layoutBackdrop()
    }

    /// Follows the animating shape by moving a subview of the panel (no window
    /// server round trip) and refreshing the small mask only when the size
    /// actually changed.
    private func layoutBackdrop() {
        guard let window, bounds.width > 0, bounds.height > 0, panel.isVisible else { return }
        let inScreen = window.convertToScreen(convert(bounds, to: nil))
        let reach = KnotchProgressiveBlur.outset
        let rect = inScreen.insetBy(dx: -reach, dy: -reach)
            .offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        backdropView.frame = rect
        updateMask(for: rect.size)
    }

    private func updateMask(for size: CGSize) {
        guard let filter, let layer = backdropView.layer,
              abs(size.width - maskSize.width) >= 1 || abs(size.height - maskSize.height) >= 1
                || abs(topCornerRadius - maskTopCornerRadius) >= 0.5
                || abs(bottomCornerRadius - maskBottomCornerRadius) >= 0.5
                || isIsland != maskIsIsland || cutsOutShape != maskCutOut,
              let mask = KnotchProgressiveBlur.makeMask(
                size: size,
                shape: NotchOuterShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    isIsland: isIsland
                ),
                cutOut: cutsOutShape
              ) else { return }
        maskCutOut = cutsOutShape
        maskSize = size
        maskTopCornerRadius = topCornerRadius
        maskBottomCornerRadius = bottomCornerRadius
        maskIsIsland = isIsland
        filter.setValue(mask, forKey: "inputMaskImage")
        // Same refresh Alcove does: clear, then re-apply.
        layer.filters = []
        layer.filters = [filter]
    }
}

// MARK: - SwiftUI

private struct KnotchProgressiveBlurHost: NSViewRepresentable, @preconcurrency Animatable {
    var isActive: Bool
    var shape: NotchOuterShape
    var cutsOutShape: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shape.topCornerRadius, shape.bottomCornerRadius) }
        set {
            shape.topCornerRadius = newValue.first
            shape.bottomCornerRadius = newValue.second
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ProgressiveBlurHostView(frame: .zero)
        view.topCornerRadius = shape.topCornerRadius
        view.bottomCornerRadius = shape.bottomCornerRadius
        view.isIsland = shape.isIsland
        view.cutsOutShape = cutsOutShape
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let view = nsView as? ProgressiveBlurHostView
        view?.topCornerRadius = shape.topCornerRadius
        view?.bottomCornerRadius = shape.bottomCornerRadius
        view?.isIsland = shape.isIsland
        view?.cutsOutShape = cutsOutShape
        view?.isActive = isActive
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? ProgressiveBlurHostView)?.shutDown()
    }
}

extension View {
    /// Attach to the notch shape view (after its clip). `isActive` should be
    /// true only while something is visibly open/active, so an idle resting
    /// notch costs nothing.
    func knotchProgressiveBlur(isEnabled: Bool, isActive: Bool, shape: NotchOuterShape, cutsOutShape: Bool) -> some View {
        background {
            if isEnabled {
                KnotchProgressiveBlurHost(isActive: isActive, shape: shape, cutsOutShape: cutsOutShape)
                    .allowsHitTesting(false)
            }
        }
    }
}
