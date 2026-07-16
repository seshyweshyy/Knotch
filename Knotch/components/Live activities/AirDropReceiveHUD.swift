//
//  AirDropReceiveHUD.swift
//  Knotch
//

import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Three-phase incoming-transfer HUD, structurally mirroring BluetoothHUDView
/// but driven by real progress instead of a fixed timer:
///
/// Phase 1 – Compact   : AirDrop icon (left) + live byte-accurate progress ring (right)
/// Phase 2 – Expanded  : shown once the transfer actually finishes — filename + actions
/// Phase 3 – Collapsing: brief checkmark before the HUD closes
struct AirDropReceiveHUD: View {
    let progress: CGFloat   // 0...1
    let filePath: String    // full path once resolved, else ""
    @Binding var isExpanded: Bool

    private enum Phase { case compact, expanded, collapsing }

    @State private var phase: Phase = .compact
    @State private var collapseTask: Task<Void, Never>? = nil
    @State private var collapseDeadline: Date? = nil
    @State private var collapsePausedRemaining: TimeInterval? = nil
    @State private var thumbnail: NSImage? = nil
    @EnvironmentObject var vm: KnotchViewModel

    private let expandedWidth: CGFloat = 300
    private let expandedContentHeight: CGFloat = 92

    private var fileURL: URL? {
        filePath.isEmpty ? nil : URL(fileURLWithPath: filePath)
    }

    /// "Received video from AirDrop" / "Received photo from AirDrop" / etc.,
    /// matching macOS's own AirDrop-completion notification wording.
    private var receivedDescription: String {
        guard let fileURL,
              let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
        else { return "Received file from AirDrop" }

        let kind: String
        if type.conforms(to: .movie) { kind = "video" }
        else if type.conforms(to: .image) { kind = "photo" }
        else if type.conforms(to: .audio) { kind = "audio" }
        else if type.conforms(to: .pdf) { kind = "document" }
        else { kind = "file" }

        return "Received \(kind) from AirDrop"
    }

    var body: some View {
        Group {
            switch phase {
            case .compact:
                compactBody
            case .expanded:
                expandedBody
            case .collapsing:
                collapsingBody
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: phase)
        .onChange(of: phase) { _, newPhase in
            isExpanded = newPhase == .expanded
        }
        .onChange(of: progress) { _, newValue in
            if newValue >= 0.999 && phase == .compact {
                withAnimation { phase = .expanded }
                scheduleCollapse()
            }
        }
        .onAppear {
            // Explicitly resync — a fresh instance always starts at
            // `phase = .compact` without "changing" into it, so
            // onChange(of: phase) never fires here. Without this, a stale
            // `isExpanded == true` left behind by a previous transfer whose
            // view was torn down mid-expanded-phase would silently carry
            // over into this new, still-compact HUD.
            phase = progress >= 0.999 ? .expanded : .compact
            isExpanded = phase == .expanded
            if phase == .expanded {
                scheduleCollapse()
            }
        }
        .onDisappear {
            collapseTask?.cancel()
            // Guard against the view disappearing mid-hover (e.g. the
            // transfer got cancelled elsewhere) without a mouse-exit ever
            // firing — don't leave the outer auto-hide timer stuck paused
            // forever with nothing left to resume it.
            KnotchViewCoordinator.shared.resumeSneakPeekAutoHide()
        }
        .onChange(of: filePath) { _, _ in
            if let fileURL { loadThumbnail(for: fileURL) }
        }
    }

    private func loadThumbnail(for url: URL) {
        thumbnail = nil
        let size = CGSize(width: 88, height: 88)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let representation else { return }
            Task { @MainActor in
                guard self.fileURL == url else { return }
                self.thumbnail = representation.nsImage
            }
        }
    }

    private func scheduleCollapse(after duration: TimeInterval = 4.0) {
        collapseTask?.cancel()
        collapsePausedRemaining = nil
        collapseDeadline = Date().addingTimeInterval(duration)
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation { phase = .collapsing }
        }
    }

    /// Freezes the expanded→collapsing countdown at its current remaining
    /// time; `resumeCollapseIfNeeded()` continues from there rather than
    /// restarting the full 6s.
    private func pauseCollapseIfNeeded() {
        guard phase == .expanded, collapseTask != nil, collapsePausedRemaining == nil else { return }
        let remaining = collapseDeadline?.timeIntervalSinceNow ?? 0
        collapsePausedRemaining = max(0.1, remaining)
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func resumeCollapseIfNeeded() {
        guard let remaining = collapsePausedRemaining else { return }
        scheduleCollapse(after: remaining)
    }

    // MARK: - Compact / collapsing (inline pill)

    private var compactBody: some View {
        inlinePill {
            TransferRingView(progress: progress, lineWidth: 2.5)
                .frame(width: 16, height: 16)
        }
    }

    private var collapsingBody: some View {
        inlinePill {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .foregroundStyle(.green)
                .frame(width: 15, height: 15)
        }
    }

    @ViewBuilder
    private func inlinePill<TrailingContent: View>(@ViewBuilder trailing: () -> TrailingContent) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                airdropIcon
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 4),
                        height: max(0, vm.effectiveClosedNotchHeight - 4)
                    )
            }
            .frame(width: max(0, vm.effectiveClosedNotchHeight - 4) + 10, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)

            HStack(spacing: 4) {
                trailing()
            }
            .padding(.trailing, 4)
            .frame(width: 30, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .transition(.opacity)
    }

    // MARK: - Expanded (completed card)

    private var expandedBody: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                thumbnailWithBadge
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("AirDrop Complete")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(receivedDescription)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))

                Spacer(minLength: 0)
            }

            if let fileURL {
                HStack(spacing: 8) {
                    pillButton(title: "Show in Finder", prominent: false) {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                    pillButton(title: "Open", prominent: true) {
                        NSWorkspace.shared.open(fileURL)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: expandedWidth, height: expandedContentHeight)
        .padding(.top, vm.effectiveClosedNotchHeight)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
        .onHover { hovering in
            if hovering {
                pauseCollapseIfNeeded()
                KnotchViewCoordinator.shared.pauseSneakPeekAutoHide()
            } else {
                resumeCollapseIfNeeded()
                KnotchViewCoordinator.shared.resumeSneakPeekAutoHide()
            }
        }
    }

    private func pillButton(title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(prominent ? Color.blue : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Icons

    private var airdropIcon: some View {
        Image(.airDropSymbol)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
    }

    private var thumbnailWithBadge: some View {
        previewThumbnail
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                airdropIcon
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .offset(x: -3, y: 3)
            }
    }

    @ViewBuilder
    private var previewThumbnail: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            ZStack {
                Color.white.opacity(0.1)
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            }
        } else {
            ZStack {
                Color.white.opacity(0.1)
                airdropIcon.padding(10)
            }
        }
    }
}

// MARK: - Progress ring

private struct TransferRingView: View {
    let progress: CGFloat
    var lineWidth: CGFloat = 3.5

    private var trimEnd: CGFloat { max(0.02, min(progress, 1.0)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: trimEnd)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
        }
    }
}
