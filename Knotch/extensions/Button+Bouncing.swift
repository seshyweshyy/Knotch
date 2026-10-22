//
//  Button+Bouncing.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
import SwiftUI
import Defaults

@MainActor
struct BouncingButtonStyle: ButtonStyle {
    let vm: KnotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                    .strokeBorder(.white.opacity(0.04), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8),
                value: configuration.isPressed
            )
    }
}

extension Button {
    @MainActor
    func bouncingStyle(vm: KnotchViewModel) -> some View {
        self.buttonStyle(BouncingButtonStyle(vm: vm))
    }
}
