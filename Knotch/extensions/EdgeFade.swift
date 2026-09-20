//
//  EdgeFade.swift
//  Knotch
//

import SwiftUI

extension View {
    // Leading/trailing fade for marquee text — clear-to-black gradients on
    // each edge with a solid strip in between, so truncated/scrolling text
    // eases out at the sides instead of cutting off hard.
    //
    // Leading defaults to no fade so text at rest remains fully visible.
    // MarqueeText adds a narrow leading fade during active movement; callers
    // can still use this modifier for the trailing edge independently.
    func edgeFade(leading: CGFloat = 0, trailing: CGFloat = 10, leadingStrength: CGFloat = 1) -> some View {
        self.mask(
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(Double(1 - leadingStrength)), .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                    .frame(width: leading)
                Rectangle().fill(Color.black)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: trailing)
            }
        )
    }
}
