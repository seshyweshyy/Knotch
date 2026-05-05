//
//  HoverButton.swift
//  Knotch
//
//  Created by Kraigo on 04.09.2024.
//

import SwiftUI

struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect

    @State private var isHovering = false
    @GestureState private var isPressed = false

    var body: some View {
        let size = CGFloat(40)

        Button(action: action) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(isPressed
                              ? Color.gray.opacity(0.35)
                              : isHovering ? Color.gray.opacity(0.2) : .clear)
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: icon)
                                .foregroundColor(iconColor)
                                .contentTransition(contentTransition)
                                .font(scale == .large ? .largeTitle : scale == .small ? .title3 : .title2)
                                .scaleEffect(isPressed ? 0.82 : 1.0)
                                .animation(.spring(response: 0.2, dampingFraction: 0.55), value: isPressed)
                        }
                }
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
        )
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) {
                isHovering = hovering
            }
        }
    }
}
