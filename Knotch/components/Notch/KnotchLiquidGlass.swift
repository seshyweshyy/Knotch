import AppKit
import SwiftUI


struct KnotchLiquidGlass: NSViewRepresentable {
    enum GlassShape {
        case notch(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat)
        case capsule
    }

    var variant: Int = 9
    var shape: GlassShape

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        guard let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return NSView()
        }
        let glass = glassClass.init(frame: .zero)
        glass.wantsLayer = true
        // Same reasoning as the CATransaction wrap in setPath(_:on:) below —
        // without this, AppKit's default implicit layer actions can animate
        // bounds/position changes on their own default curve, independent of
        // the SwiftUI spring actually driving the resize.
        glass.layer?.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "path": NSNull(),
        ]

        applyProperties(to: glass)

        #if DEBUG
        // Logged once here (not in applyProperties, which also runs on every
        // updateNSView) since these values are static for the glass view's
        // lifetime — no need to spam the console on every SwiftUI update.
        print("""
        KnotchGlassDebug: _variant=\(glass.value(forKey: "_variant") ?? "nil") \
        style=\(glass.value(forKey: "style") ?? "nil") \
        _scrimState=\(glass.value(forKey: "_scrimState") ?? "nil") \
        _subduedState=\(glass.value(forKey: "_subduedState") ?? "nil") \
        _contentLensing=\(glass.value(forKey: "_contentLensing") ?? "nil") \
        _adaptiveAppearance=\(glass.value(forKey: "_adaptiveAppearance") ?? "nil")
        """)
        #endif

        // updateNSView's nsView.bounds can lag one layout pass behind the
        // final SwiftUI-assigned frame, which produces a path that's the
        // wrong size — corners still land close enough to look plausible,
        // but the straight edges need exact bounds to align, so they show
        // no lensing at all. Recomputing on AppKit's own frame-change
        // notification instead guarantees bounds are final when we read them.
        // Registering with a selector (rather than the block+queue form)
        // matters here: NotificationCenter delivers block observers with an
        // explicit queue asynchronously (one run-loop tick late), which
        // during the open spring made the glass visibly lag a beat behind
        // the SwiftUI-driven black mask before snapping into place.
        // Selector-based observers are invoked synchronously at post time,
        // matching the mask's per-frame animation.
        glass.postsFrameChangedNotifications = true
        context.coordinator.glassView = glass
        context.coordinator.shape = shape
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleFrameChange),
            name: NSView.frameDidChangeNotification,
            object: glass
        )

        return glass
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyProperties(to: nsView)
        context.coordinator.shape = shape
        context.coordinator.applyPath()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.frameDidChangeNotification,
            object: nsView
        )
    }

    // Setting `style` resets _variant back to a style-appropriate default
    // internally, so _variant must be set AFTER style (and everything else)
    // or it gets silently discarded — confirmed by debug logging showing
    // _variant read back correctly right after being set, then reverting to
    // 2 by the time style had also been set. Also needs reapplying on every
    // updateNSView call (not just once in makeNSView): NSGlassEffectView
    // resets several of these back to its own defaults once the view is
    // actually attached to a window, which happens after makeNSView returns.
    private func applyProperties(to view: NSView) {
        view.setValue(false, forKey: "_adaptiveAppearance")
        view.setValue(0, forKey: "_scrimState")
        view.setValue(false, forKey: "_subduedState")
        view.setValue(true, forKey: "_contentLensing")
        // Public NSGlassEffectViewStyle: .regular (0, what SwiftUI's own
        // `.glassEffect()` modifier defaults to) is the "Standard glass
        // effect style" — more opaque/tinted by design, which is why views
        // using the public modifier read as frosted rather than truly
        // glassy. .clear (1) is the fully transparent one used here.
        view.setValue(1, forKey: "style")
        view.setValue(variant, forKey: "_variant")
    }

    final class Coordinator: NSObject {
        weak var glassView: NSView?
        var shape: GlassShape = .capsule

        @objc func handleFrameChange(_ notification: Notification) {
            applyPath()
        }

        // NSGlassEffectView's edge lensing/refraction is tied to its own
        // path, not to any external SwiftUI .clipShape() applied afterward —
        // a plain cornerRadius rounded rect only lenses at its own corners,
        // so once reclipped to a different shape, the straight edges get no
        // refraction. Feeding the real geometry into the private _path
        // property makes the lensing follow every edge, whichever shape
        // this instance is standing in for (notch or capsule alike).
        func applyPath() {
            guard let view = glassView, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let path: CGPath
            switch shape {
            case .notch(let topCornerRadius, let bottomCornerRadius):
                path = NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                    .path(in: view.bounds).cgPath
            case .capsule:
                path = Capsule(style: .continuous).path(in: view.bounds).cgPath
            }

            // SwiftUI Path uses a top-left origin; NSGlassEffectView
            // (isFlipped == false) uses AppKit's bottom-left origin, so
            // flip before setting.
            var transform = view.isFlipped
                ? CGAffineTransform.identity
                : CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -view.bounds.height)
            let flippedPath = path.copy(using: &transform) ?? path

            setPath(flippedPath, on: view)
        }

        private func setPath(_ path: CGPath, on view: NSView) {
            let selector = NSSelectorFromString("_setPath:")
            guard view.responds(to: selector),
                  let method = class_getInstanceMethod(type(of: view), selector) else { return }

            typealias SetPathIMP = @convention(c) (AnyObject, Selector, CGPath) -> Void
            let imp = method_getImplementation(method)
            let function = unsafeBitCast(imp, to: SetPathIMP.self)

            // NSGlassEffectView morphs path changes with its own internal
            // animation (that's the "liquid" part of the effect), on a curve
            // independent of whatever SwiftUI animation is driving the rest
            // of the notch. That's what made the glass edges visibly lag
            // flat/unlensed before catching up to the real shape, no matter
            // how promptly applyPath() itself was called. Disabling implicit
            // actions for this transaction forces the path to apply
            // instantly, so the glass tracks the same per-frame shape as the
            // SwiftUI-driven black mask instead of animating to it on its
            // own schedule.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            function(view, selector, path)
            CATransaction.commit()
        }
    }
}
