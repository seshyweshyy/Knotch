import AppKit
import SwiftUI


final class KnotchLiquidGlassView: NSView {
    private weak var glassView: NSView?

    /// 2 = Dock material
    var variant: Int = 2
    var glassCornerRadius: CGFloat = 16.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupGlass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupGlass()
    }

    private func setupGlass() {
        guard let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return }
        let glass = glassClass.init(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        glassView = glass

        setVariant(variant, on: glass)

        // Confirmed-valid keys — plain Swift KVC is safe here since these
        // are real properties, not guesses. No ObjC exception wrapper needed.
        glass.setValue(0, forKey: "_scrimState")
        glass.setValue(false, forKey: "_subduedState")
        glass.setValue(glassCornerRadius, forKey: "cornerRadius")
    }

    private func setVariant(_ variant: Int, on view: NSView) {
        let selector = NSSelectorFromString("set_variant:")
        guard view.responds(to: selector),
              let method = class_getInstanceMethod(type(of: view), selector) else { return }

        typealias SetVariantIMP = @convention(c) (AnyObject, Selector, Int) -> Void
        let imp = method_getImplementation(method)
        let function = unsafeBitCast(imp, to: SetVariantIMP.self)
        function(view, selector, variant)
    }

    override func layout() {
        super.layout()
        glassView?.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        needsLayout = true
        glassView?.needsDisplay = true
        needsDisplay = true
    }
}

struct KnotchLiquidGlass: NSViewRepresentable {
    var variant: Int = 2
    var glassCornerRadius: CGFloat = 16.0

    func makeNSView(context: Context) -> KnotchLiquidGlassView {
        let view = KnotchLiquidGlassView()
        view.variant = variant
        view.glassCornerRadius = glassCornerRadius
        return view
    }

    func updateNSView(_ nsView: KnotchLiquidGlassView, context: Context) {
        nsView.needsLayout = true
        nsView.needsDisplay = true
    }
}
