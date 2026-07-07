import AppKit
import SwiftUI

/// Wraps Apple's private NSGlassEffectView pinned to a specific undocumented
/// "variant" (0–19) via runtime invocation of set_variant: — Atoll's
/// technique, bypassing the public .glassEffect() API which only exposes
/// .regular/.clear.
final class Variant11GlassView: NSView {
    private weak var glassView: NSView?

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
        setVariant(11, on: glass)
    }

    /// Calls the private `set_variant:` selector safely. NSGlassEffectView
    /// takes a primitive Int, so perform(_:with:) can't be used (it only
    /// passes object pointers) — instead we cast the method's IMP to a
    /// C function pointer with the correct signature and call it directly.
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
}

struct KnotchVariant11Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> Variant11GlassView {
        Variant11GlassView()
    }

    func updateNSView(_ nsView: Variant11GlassView, context: Context) {}
}
