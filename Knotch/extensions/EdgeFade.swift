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
    // Leading defaults to no fade at all: text starts flush at the leading
    // edge with no reserved space to shift it into, so any nonzero fade there
    // visibly dims the first character — and unlike the trailing edge, there's
    // nothing being scrolled/truncated in at the start for a fade to soften.
    // The trailing edge — where content actually does scroll/truncate — keeps
    // the fuller fade.
    func edgeFade(leading: CGFloat = 0, trailing: CGFloat = 10) -> some View {
        self.mask(
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: leading)
                Rectangle().fill(Color.black)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: trailing)
            }
        )
    }
}
