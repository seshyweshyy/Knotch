//
//  UpdateWindowView.swift
//  Knotch
//

import Sparkle
import SwiftUI

/// Placeholder rendering for every update-flow phase. Just needs to be
/// functionally correct for this pass — the designed states (checking,
/// found) get restyled in the follow-up visual pass.
struct UpdateWindowView: View {
    @ObservedObject var state: UpdateFlowState
    /// Closes the hosting window after a reply/acknowledge has been sent.
    let closeWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 12) {
                phaseContent
            }
        }
        .padding(20)
        .frame(width: 600, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
            case .idle:
                EmptyView()

            case .checking(let cancel):
                Text("Checking for updates…")
                    .fontWeight(.bold)
                ProgressView()
                    .progressViewStyle(.linear)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        cancel()
                        closeWindow()
                    }
                    .updateSubtleGlassButton()
                }

            case .found, .downloading, .extracting, .readyToInstall, .installing:
                if let item = state.foundItem {
                    UpdateFoundView(item: item, state: state, closeWindow: closeWindow)
                } else {
                    // Shouldn't normally happen (these phases always follow .found),
                    // but fall back to a minimal screen rather than showing nothing.
                    fallbackProgressContent
                }

            case .notFound(let acknowledge):
                Text("You're up to date!")
                    .font(.headline)
                HStack {
                    Spacer()
                    Button("OK") {
                        acknowledge()
                        closeWindow()
                    }
                    .updateProminentGlassButton()
                    .keyboardShortcut(.defaultAction)
                }

            case .error(let error, let acknowledge):
                Text("Update Error")
                    .font(.headline)
                Text(error.localizedDescription)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK") {
                        acknowledge()
                        closeWindow()
                    }
                    .updateProminentGlassButton()
                    .keyboardShortcut(.defaultAction)
                }
        }
    }

    @ViewBuilder
    private var fallbackProgressContent: some View {
        switch state.phase {
        case .downloading(let cancel):
            Text("Downloading update…")
            ProgressView()
                .progressViewStyle(.linear)
            HStack {
                Spacer()
                Button("Cancel") {
                    cancel()
                    closeWindow()
                }
                .updateSubtleGlassButton()
            }
        case .extracting(let progress):
            Text("Extracting update…")
            ProgressView(value: progress, total: 1)
        case .readyToInstall(let reply):
            Text("Update is ready to install")
                .font(.headline)
            HStack {
                Spacer()
                Button("Install and Relaunch") {
                    reply(.install)
                }
                .updateProminentGlassButton()
                .keyboardShortcut(.defaultAction)
            }
        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Installing…")
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Button styling

/// Subtle glass button matching Settings' style — native Liquid Glass on
/// macOS 26+, falling back to a plain bordered button before that.
@available(macOS 26.0, *)
private struct UpdateGlassButtonStyle: ButtonStyle {
    var glass: Glass
    var cornerRadius: CGFloat = 15

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .glassEffect(glass, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension View {
    @ViewBuilder
    func updateSubtleGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(UpdateGlassButtonStyle(glass: Glass.regular.tint(Color(white: 0.28)).interactive()))
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Accent-tinted glass for the primary action (Install) — mirrors Settings' prominent style.
    @ViewBuilder
    func updateProminentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self
                .foregroundStyle(.white)
                .buttonStyle(UpdateGlassButtonStyle(glass: Glass.regular.tint(Color(nsColor: .systemBlue)).interactive()))
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Small pill used for the "current → new version" badge on the found-update screen.
    @ViewBuilder
    func updateGlassBadge() -> some View {
        if #available(macOS 26.0, *) {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        } else {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.4)))
        }
    }
}
