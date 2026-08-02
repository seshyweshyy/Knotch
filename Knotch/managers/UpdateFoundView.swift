//
//  UpdateFoundView.swift
//  Knotch
//

import Sparkle
import SwiftUI

/// The "update found" screen — version badge plus collapsible release-notes
/// sections (New Features / Fixes), each with dividers between its items.
struct UpdateFoundView: View {
    let item: SUAppcastItem
    @ObservedObject var state: UpdateFlowState
    let closeWindow: () -> Void

    @StateObject private var notesViewModel = ReleaseNotesViewModel()
    @State private var collapsedSectionIDs: Set<Int> = []

    private struct ReleaseSection: Identifiable {
        let id: Int
        let icon: (symbol: String, label: String, color: Color)?
        let title: AttributedString
        var items: [MarkdownBlock]
    }

    private func sections(from blocks: [MarkdownBlock]) -> [ReleaseSection] {
        var sections: [ReleaseSection] = []
        for block in blocks {
            if case .header = block.kind {
                sections.append(ReleaseSection(id: sections.count, icon: block.sectionIcon, title: block.text, items: []))
            } else if !sections.isEmpty {
                sections[sections.count - 1].items.append(block)
            }
        }
        return sections
    }

    private var currentVersion: String {
        Bundle.main.releaseVersionNumber ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Knotch v\(item.displayVersionString) is available — you currently have v\(currentVersion) installed. \nWould you like to install the update now?")
                .font(.headline)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 6) {
                Text(currentVersion)
                Image(systemName: "arrow.right")
                Text(item.displayVersionString)
            }
            .font(.system(.callout, design: .monospaced))
            .updateGlassBadge()
            .frame(maxWidth: .infinity, alignment: .center)

            switch notesViewModel.state {
            case .loading:
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            case .failed:
                EmptyView()
            case .loaded(let blocks):
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sections(from: blocks)) { section in
                            releaseSection(section)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 420)
            }

            footer
        }
        .task(id: item.displayVersionString) {
            await notesViewModel.load(version: item.displayVersionString)
        }
    }

    /// Reacts to the flow's current phase — the found-update screen stays on
    /// screen through downloading/extracting/ready-to-install instead of
    /// being swapped for a separate progress window: just this footer row
    /// changes from buttons to a bare progress bar and back.
    @ViewBuilder
    private var footer: some View {
        switch state.phase {
        case .found(_, _, let reply):
            HStack {
                Spacer()
                Button("Remind Me Later") {
                    reply(.dismiss)
                    closeWindow()
                }
                .updateSubtleGlassButton()
                Button("Download") {
                    reply(.install)
                }
                .updateProminentGlassButton()
                .keyboardShortcut(.defaultAction)
            }

        case .downloading:
            HStack(spacing: 10) {
                if state.downloadExpectedLength > 0 {
                    ProgressView(value: Double(state.downloadReceivedLength), total: Double(state.downloadExpectedLength))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text("Downloading…")
            }

        case .extracting(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress, total: 1)
                Text("Downloading…")
            }

        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Installing…")
            }

        case .readyToInstall(let reply):
            HStack {
                Spacer()
                Button("Install and Relaunch") {
                    reply(.install)
                }
                .updateProminentGlassButton()
                .keyboardShortcut(.defaultAction)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func releaseSection(_ section: ReleaseSection) -> some View {
        let isExpanded = !collapsedSectionIDs.contains(section.id)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                if let icon = section.icon {
                    Image(systemName: icon.symbol)
                        .foregroundStyle(icon.color)
                    Text(icon.label)
                } else {
                    Text(section.title)
                }
            }
            .font(.title3)
            .fontWeight(.semibold)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        collapsedSectionIDs.insert(section.id)
                    } else {
                        collapsedSectionIDs.remove(section.id)
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, block in
                        if index > 0 {
                            Divider()
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                            Text(block.text)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
