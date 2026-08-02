//
//  ReleaseNotesView.swift
//  Knotch
//

import SwiftUI

@MainActor
final class ReleaseNotesViewModel: ObservableObject {
    enum State {
        case loading
        case loaded([MarkdownBlock])
        case failed
    }

    @Published private(set) var state: State = .loading

    func load(version: String) async {
        guard let url = URL(string: "https://api.github.com/repos/seshyweshyy/Knotch/releases/tags/v\(version)") else {
            state = .failed
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .failed
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let markdown = try AttributedString(
                markdown: release.body,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            )
            state = .loaded(markdownBlocks(from: markdown))
        } catch {
            state = .failed
        }
    }
}

private struct GitHubRelease: Decodable {
    let body: String
}

// MARK: - Minimal markdown block parsing

enum MarkdownBlockKind {
    case header(level: Int)
    case listItem
    case paragraph
}

struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: MarkdownBlockKind
    let text: AttributedString
}

private func markdownBlocks(from attributed: AttributedString) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var currentIdentity: Int?

    for run in attributed.runs {
        let components = run.presentationIntent?.components ?? []
        // `components` is ordered innermost-first; the innermost (most specific)
        // block is what should distinguish e.g. one list item's paragraph from the next.
        let identity = components.first?.identity
        let kind: MarkdownBlockKind
        if let headerLevel = components.compactMap({ component -> Int? in
            if case .header(let level) = component.kind { return level }
            return nil
        }).first {
            kind = .header(level: headerLevel)
        } else if components.contains(where: { if case .listItem = $0.kind { return true }; return false }) {
            kind = .listItem
        } else {
            kind = .paragraph
        }

        if identity != nil, identity == currentIdentity, let last = blocks.last {
            blocks[blocks.count - 1] = MarkdownBlock(id: last.id, kind: last.kind, text: last.text + attributed[run.range])
        } else {
            currentIdentity = identity
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: AttributedString(attributed[run.range])))
        }
    }

    return blocks.filter { block in
        if block.text.characters.isEmpty { return false }
        // Drop the release's own H1 title (e.g. "Knotch v1.7.1") since it
        // duplicates the "What's New in vX.X.X" section header above it.
        if case .header(let level) = block.kind, level == 1 { return false }
        return true
    }
}

// MARK: - Section icons

// Release notes are hand-written on GitHub with a leading emoji or `<img>` icon
// (e.g. "✨ New Features"); neither renders through AttributedString's markdown
// parser, so headers are matched by their trailing label and paired with the
// equivalent SF Symbol instead.
extension MarkdownBlock {
    var sectionIcon: (symbol: String, label: String, color: Color)? {
        guard case .header = kind else { return nil }
        let label = String(text.characters).trimmingCharacters(in: .whitespaces)
        if label.hasSuffix("New Features") { return ("sparkles", "New Features", Color(red: 0.8549, green: 0.7333, blue: 0.3333)) }
        if label.hasSuffix("Fixes") { return ("wrench.adjustable.fill", "Fixes", Color(red: 0.4431, green: 0.5804, blue: 0.7216)) }
        return nil
    }
}

struct ReleaseNotesView: View {
    @StateObject private var viewModel = ReleaseNotesViewModel()
    let version: String

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            case .failed:
                EmptyView()
            case .loaded(let blocks):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        switch block.kind {
                        case .header:
                            HStack(spacing: 6) {
                                if let icon = block.sectionIcon {
                                    Image(systemName: icon.symbol)
                                        .foregroundStyle(icon.color)
                                    Text(icon.label)
                                } else {
                                    Text(block.text)
                                }
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.top, index == 0 ? 0 : 6)
                        case .listItem:
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(block.text)
                            }
                            .foregroundStyle(.secondary)
                        case .paragraph:
                            Text(block.text)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: version) {
            await viewModel.load(version: version)
        }
    }
}
