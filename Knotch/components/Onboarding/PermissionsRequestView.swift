//
//  PermissionsRequestView.swift
//  Knotch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI

struct PermissionRequestView: View {
    let icon: Image
    let title: String
    let description: String
    let privacyNote: String?
    var iconColor: Color = .effectiveAccent
    var titleFont: Font = .title
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 56)
                .foregroundColor(iconColor)
                .padding(.top, 32)
                .staggeredEntrance(4)

            Text(title)
                .font(titleFont)
                .fontWeight(.semibold)
                .staggeredEntrance(3)

            Text(description)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .staggeredEntrance(2)

            if let privacyNote = privacyNote {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.secondary)
                    Text(privacyNote)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.bottom, 8)
                .padding(.horizontal)
                .staggeredEntrance(1)
            }

            HStack {
                Button("Not Now") { onSkip() }
                    .settingsSubtleGlassButton()
                Button("Allow Access") { onAllow() }
                    .settingsProminentGlassButton()
            }
            .padding(.top, 10)
            .staggeredEntrance(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow, alpha: 0.94)
                .ignoresSafeArea()
        )
    }
}
