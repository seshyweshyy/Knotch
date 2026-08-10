//
//  UIModeSelectionView.swift
//  Knotch
//

import SwiftUI
import Defaults

struct UIModeSelectionView: View {
    let onContinue: () -> Void

    @State private var useCompactMode: Bool = Defaults[.enableCompactUI]

    var body: some View {
        VStack(spacing: 20) {
            Text("Choose Your Layout")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 24)

            Text("Pick how Knotch's UI should look. You can change this later in Settings.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            ScrollView {
                VStack(spacing: 14) {
                    UIModeOptionRow(
                        title: "Normal",
                        description: "The full-featured layout, with the tray, header icons, and expanded media player.",
                        image: Image("OnboardingNormalModePreview"),
                        isSelected: !useCompactMode
                    )
                    .onTapGesture {
                        useCompactMode = false
                    }

                    UIModeOptionRow(
                        title: "Compact",
                        description: "A smaller, notch-hugging layout that hides the tray and header icons.",
                        image: Image("OnboardingCompactModePreview"),
                        imageHeight: 130,
                        isSelected: useCompactMode
                    )
                    .onTapGesture {
                        useCompactMode = true
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            Button("Continue") {
                Defaults[.enableCompactUI] = useCompactMode
                onContinue()
            }
            .settingsProminentGlassButton()
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}

private struct UIModeOptionRow: View {
    let title: String
    let description: String
    let image: Image
    var imageHeight: CGFloat = 90
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .white : .secondary.opacity(0.5))
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
            }

            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
                .background(Color.black.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .settingsGlassSelectableCard(isSelected: isSelected)
        .contentShape(Rectangle())
    }
}

#Preview {
    UIModeSelectionView(onContinue: {})
        .frame(width: 400, height: 600)
}
