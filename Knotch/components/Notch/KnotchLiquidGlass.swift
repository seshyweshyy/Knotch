import AppKit
import SwiftUI


struct KnotchLiquidGlass: NSViewRepresentable {
    var variant: Int = 9
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        guard let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return NSView()
        }
        let glass = glassClass.init(frame: .zero)

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
        glass.postsFrameChangedNotifications = true
        context.coordinator.glassView = glass
        context.coordinator.topCornerRadius = topCornerRadius
        context.coordinator.bottomCornerRadius = bottomCornerRadius
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: glass,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.applyPath()
        }

        return glass
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyProperties(to: nsView)
        context.coordinator.topCornerRadius = topCornerRadius
        context.coordinator.bottomCornerRadius = bottomCornerRadius
        context.coordinator.applyPath()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
        // Public NSGlassEffectViewStyle: .regular (0, the default we were
        // never overriding) is the "Standard glass effect style" — more
        // opaque/tinted by design. .clear (1) is the fully transparent one.
        view.setValue(1, forKey: "style")
        view.setValue(variant, forKey: "_variant")
    }

    final class Coordinator {
        weak var glassView: NSView?
        var topCornerRadius: CGFloat = 0
        var bottomCornerRadius: CGFloat = 0
        var frameObserver: NSObjectProtocol?

        // NSGlassEffectView's edge lensing/refraction is tied to its own
        // path, not to any external SwiftUI .clipShape() applied afterward —
        // a plain cornerRadius rounded rect only lenses at its own corners,
        // so once reclipped to the notch's flat-top shape, the straight
        // side edges get no refraction. Feeding the real NotchShape geometry
        // into the private _path property makes the lensing follow every edge.
        func applyPath() {
            guard let view = glassView, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let shape = NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
            let path = shape.path(in: view.bounds).cgPath

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
            function(view, selector, path)
        }
    }
}
