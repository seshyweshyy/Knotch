//
//  ListItemPopover.swift
//  Knotch
//
//  Created by Richard Kunkli on 15/09/2024.
//

import SwiftUI

struct ListItemPopover<Content: View>: View {
    let content: () -> Content

    @State private var isPresented: Bool = false
    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.white)
        }
        .buttonStyle(InfoCircleGlassButtonStyle())
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing, content: {
            content()
                .padding()
        })
    }
}

private struct InfoCircleGlassButtonStyle: ButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .padding(8)
                .contentShape(Circle())
                .glassEffect(Glass.regular.tint(Color(white: 0.28)).interactive(), in: .circle)
                .opacity(configuration.isPressed ? 0.75 : 1)
        } else {
            configuration.label
                .padding(6)
                .background(
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(configuration.isPressed ? 0.6 : 0.4))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                )
                .contentShape(Circle())
        }
    }
}

