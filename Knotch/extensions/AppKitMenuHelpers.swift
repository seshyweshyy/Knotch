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
