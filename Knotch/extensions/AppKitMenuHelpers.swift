import SwiftUI
import AppKit

extension NSMenuItem {
    // preferredImageVisibility doesn't exist pre-macOS 27, where images
    // already show by default — only 27+ needs the explicit opt-in.
    static func withIcon(
        _ title: String,
        systemImage: String,
        action: Selector?,
        keyEquivalent: String = "",
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        if #available(macOS 27, *) {
            item.preferredImageVisibility = .visible
        }
        return item
    }

    static func disabledInfo(_ title: String, fontSize: CGFloat? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let fontSize {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.menuFont(ofSize: fontSize)]
            )
        }
        return item
    }
}

// Claims hit-testing only for right-click/control-click, so it can sit as an
// .overlay() (required for menu(for:) to ever be asked) without swallowing
// the left-click/drag gestures the notch view underneath depends on.
private final class ContextMenuOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isRightClick = event.type == .rightMouseDown || event.type == .rightMouseUp
        let isControlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        return (isRightClick || isControlClick) ? super.hitTest(point) : nil
    }
}

/// Hosts a native NSMenu as the right-click/control-click context menu for
/// the SwiftUI view it's attached to. SwiftUI's own `.contextMenu` has no way
/// to set `NSMenuItem.preferredImageVisibility`, so icons don't survive
/// macOS 27's default hiding of menu item images.
///
/// Must be applied with `.overlay()`, not `.background()` — AppKit's
/// menu(for:) hit-test always resolves to the frontmost view at the click
/// point, so a background view is never even asked.
struct NativeContextMenu: NSViewRepresentable {
    let menu: NSMenu

    func makeNSView(context: Context) -> NSView {
        let view = ContextMenuOverlayView()
        view.menu = menu
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.menu = menu
    }
}
