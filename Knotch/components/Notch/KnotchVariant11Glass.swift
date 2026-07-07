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

    // Private compositing views like NSGlassEffectView only fully render
    // once attached to a real window — force a refresh at that point so
    // the preview doesn't start out faint/half-rendered.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        needsLayout = true
        glassView?.needsDisplay = true
        needsDisplay = true
    }
}

struct KnotchVariant11Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> Variant11GlassView {
        Variant11GlassView()
    }

    func updateNSView(_ nsView: Variant11GlassView, context: Context) {
        nsView.needsLayout = true
        nsView.needsDisplay = true
    }
}
