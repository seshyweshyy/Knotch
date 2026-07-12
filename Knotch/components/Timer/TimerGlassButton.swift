//
//  TimerGlassButton.swift
//  Knotch
//
//  Shared circular glass button for timer controls, used by both the
//  notch popup (TimerListView) and the lock-screen widget
//  (LiquidGlassTimerWidget) so they stay visually consistent.
//

import SwiftUI

struct TimerGlassButton: View {
    let systemImage: String
    let iconColor: Color
    let tint: Color
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if #available(macOS 26.0, *) {
                Circle()
                    .fill(.clear)
                    .frame(width: size, height: size)
                    .glassEffect(.regular.tint(tint), in: .circle)
                    .overlay { Image(systemName: systemImage).foregroundStyle(iconColor) }
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: size, height: size)
                    .overlay { Image(systemName: systemImage).foregroundStyle(iconColor) }
            }
        }
        .buttonStyle(.plain)
    }
}
