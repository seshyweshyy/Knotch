//
//  OnboardingFinishView.swift
//  Knotch
//
//  Created by Alexander on 2025-06-23.
//


import SwiftUI

struct OnboardingFinishView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundColor(Color(red: 0.96, green: 0.77, blue: 0.24))
                .padding()
                .staggeredEntrance(3)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)
                .staggeredEntrance(2)

            Text("You can now enjoy the app. If you want to tweak things further, you can always visit the settings.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .staggeredEntrance(1)

            Spacer()
            Spacer()

            VStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Label("Customize in Settings", systemImage: "gearshape.fill")
                }
                .settingsSubtleGlassButton()

                Button("Finish", action: onFinish)
                    .settingsProminentGlassButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .staggeredEntrance(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow, alpha: 0.94)
                .ignoresSafeArea()
        )
    }
}

#Preview {
    OnboardingFinishView(onFinish: { }, onOpenSettings: { })
}
