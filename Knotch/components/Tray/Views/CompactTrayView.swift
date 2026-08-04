//
//  CompactTrayView.swift
//  Knotch
//
//  Compact mode's tray surface: a transient drop-zone that appears while a
//  file is being dragged near the notch (a live-activity-style overlay),
//  and a persistent horizontal tray page once the tray actually has items —
//  reachable the same way CompactCalendarView is, by swiping.
//

import SwiftUI
import UniformTypeIdentifiers
import Defaults

// Transient live-activity overlay: three independent drop targets (AirDrop,
// Tray, Converter) shown side by side while a file is being dragged near the
// notch. Each square is its own native onDrop target, so macOS tracks which
// one the cursor is over during the drag the same way it would for any other
// multi-target drop UI.
private enum CompactDropTargetKind: CaseIterable, Equatable {
    case airDrop, tray, converter
}

struct CompactTrayDropZoneView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @StateObject private var quickShare = QuickShareService.shared
    @Default(.quickShareProvider) private var quickShareProviderID
    @State private var airDropHostView: NSView?
    // Single source of truth for which box the cursor is over — native onDrop
    // targeting is already mutually exclusive between sibling drop targets,
    // so one optional reads more clearly than three independent bools and is
    // what the width-redistribution math below keys off of.
    @State private var targetedKind: CompactDropTargetKind?

    // Same setting the standard tray's Quick Share picker writes to (see
    // Settings' Compact tab, "Tray" section) — no longer hardcoded to
    // AirDrop, so this square shares through whatever the user picked there.
    private var shareProvider: QuickShareProvider? {
        quickShare.availableProviders.first { $0.id == quickShareProviderID }
            ?? quickShare.availableProviders.first { $0.id == "AirDrop" }
    }

    @ViewBuilder
    private var shareProviderIcon: some View {
        if let imgData = shareProvider?.imageData, let nsImg = NSImage(data: imgData) {
            Image(nsImage: nsImg)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
        } else {
            Image(.airDropSymbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: CompactDropZoneMetrics.spacing) {
                CompactDropTargetSquare(
                    title: LocalizedStringKey(shareProvider?.id ?? "AirDrop"),
                    tint: .blue,
                    isTargeted: targetedKind == .airDrop
                ) {
                    shareProviderIcon
                }
                .background(NSViewHost(view: $airDropHostView))
                .frame(width: width(for: .airDrop, totalWidth: geo.size.width))
                .onDrop(of: [.fileURL, .url, .data], isTargeted: targetedBinding(for: .airDrop)) { providers in
                    guard let shareProvider else { return false }
                    vm.dropEvent = true
                    vm.isCompactDragCommitted = true
                    let hostView = airDropHostView
                    Task { await quickShare.shareDroppedFiles(providers, using: shareProvider, from: hostView) }
                    vm.finishCompactDragOverlay()
                    return true
                }

                CompactDropTargetSquare(title: "Tray", tint: nil, isTargeted: targetedKind == .tray) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                }
                .frame(width: width(for: .tray, totalWidth: geo.size.width))
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: targetedBinding(for: .tray)) { providers in
                    vm.dropEvent = true
                    // Same fix as the Converter square: TrayStateViewModel's
                    // plain load(_:) is fire-and-forget, so revealing .tray
                    // right after calling it used to race the actual async
                    // add — resolvedCompactPage would see the tray still
                    // empty for a beat and fall back to music before the
                    // items landed and it snapped over to tray. Awaiting the
                    // load before revealing removes that gap entirely.
                    vm.isCompactDragCommitted = true
                    Task { @MainActor in
                        await TrayStateViewModel.shared.loadAwaiting(providers)
                        vm.finishCompactDragOverlay(revealing: .tray)
                    }
                    return true
                }

                CompactDropTargetSquare(title: "Converter", tint: .green, isTargeted: targetedKind == .converter) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .frame(width: width(for: .converter, totalWidth: geo.size.width))
                .onDrop(of: [.fileURL, .url, .data], isTargeted: targetedBinding(for: .converter)) { providers in
                    guard let provider = providers.first else { return false }
                    vm.dropEvent = true
                    // Marks the drop as "being handled" immediately so a stray
                    // drag-exit-region event firing while extractFileURL()
                    // resolves can't be mistaken for an abandoned drag and
                    // close the notch — see isCompactDragCommitted and
                    // KnotchApp.handleDragExitsNotchRegion. The page itself
                    // only gets revealed once setFile actually succeeds, so
                    // there's no premature switch to .converter before
                    // FileConverterViewModel actually has something to show.
                    vm.isCompactDragCommitted = true
                    Task { @MainActor in
                        // extractFileURL() alone isn't always enough — Tray's
                        // TrayDropService falls through extractURL()/
                        // extractItem() too for providers that don't register
                        // public.file-url directly, and Converter only had the
                        // one path, silently doing nothing on a drop it
                        // couldn't resolve.
                        guard let fileURL = await provider.resolveDroppedFileURL() else {
                            NSLog("Converter drop: could not resolve a file URL from \(provider.registeredTypeIdentifiers)")
                            vm.finishCompactDragOverlay()
                            return
                        }
                        do {
                            try FileConverterViewModel.shared.setFile(fileURL)
                            vm.finishCompactDragOverlay(revealing: .converter)
                        } catch {
                            NSLog("Converter drop failed to load \(fileURL.path): \(error.localizedDescription)")
                            vm.finishCompactDragOverlay()
                        }
                    }
                    return true
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: targetedKind)
        }
        .padding(.horizontal, CompactDropZoneMetrics.horizontalPadding)
        .padding(.vertical, CompactDropZoneMetrics.verticalPadding)
        .frame(height: compactContentHeight, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    // Dock-magnification-style layout: the targeted box claims a larger share
    // of the row's width while its two neighbors compress to make room, all
    // riding the same spring.
    private func targetedBinding(for kind: CompactDropTargetKind) -> Binding<Bool> {
        Binding(
            get: { targetedKind == kind },
            set: { isTargeted in
                if isTargeted {
                    targetedKind = kind
                } else if targetedKind == kind {
                    targetedKind = nil
                }
            }
        )
    }

    private func width(for kind: CompactDropTargetKind, totalWidth: CGFloat) -> CGFloat {
        let baseWeight: CGFloat = 1
        let expandedWeight: CGFloat = 1.6
        let availableWidth = max(totalWidth - CompactDropZoneMetrics.spacing * CGFloat(CompactDropTargetKind.allCases.count - 1), 0)
        let totalWeight = CompactDropTargetKind.allCases.reduce(CGFloat.zero) { partial, candidate in
            partial + (candidate == targetedKind ? expandedWeight : baseWeight)
        }
        let myWeight = kind == targetedKind ? expandedWeight : baseWeight
        return availableWidth * myWeight / totalWeight
    }
}

// Metrics for the three drop-zone squares — horizontal/vertical padding
// scaled down for Compact mode's much narrower fixed panel (420pt wide).
enum CompactDropZoneMetrics {
    static let cornerRadius: CGFloat = 18
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
}

// Box design: a thick dashed, tinted outline over a mostly-transparent fill
// that only washes in once targeted, with the icon and label centered —
// `tint: nil` gives Tray its own colorless (white-on-white) treatment; a
// color gives AirDrop/Converter their tinted ones.
private struct CompactDropTargetSquare<Icon: View>: View {
    let title: LocalizedStringKey
    let tint: Color?
    let isTargeted: Bool
    @ViewBuilder let icon: () -> Icon

    private var fillColor: Color {
        (tint ?? .white).opacity(isTargeted ? 0.16 : 0)
    }

    private var strokeColor: Color {
        (tint ?? .white).opacity(isTargeted ? 0.9 : 0.5)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: CompactDropZoneMetrics.cornerRadius, style: .continuous)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: CompactDropZoneMetrics.cornerRadius, style: .continuous)
                    .stroke(strokeColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [12, 10]))
            }
            .overlay {
                VStack(spacing: 6) {
                    icon()
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
    }
}

struct CompactTrayView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @StateObject var tvm = TrayStateViewModel.shared
    @StateObject var selection = TraySelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    // Held onto for a beat after the tray empties out — mirrors
    // KnotchViewModel.dismissCompactConverterPage's "leave the page first,
    // let state catch up after" choreography, but keyed off the tray's own
    // item count hitting zero from *any* removal path (the "All" button, an
    // individual item's own remove button, or auto-remove-on-drag-out)
    // rather than a single dismiss button. Deliberately never reset back to
    // empty locally — this view is about to be removed by the page-switch
    // transition triggered below, and should keep showing its last real
    // content for that transition instead of snapping to a blank scroll view
    // first.
    @State private var displayedItems: [TrayItem] = TrayStateViewModel.shared.items
    private let spacing: CGFloat = 8

    // Same technique as CompactMusicPlayerView's notch-hugging header — the
    // header row overlaps upward alongside the physical notch cutout instead
    // of sitting in normal flow beneath it.
    private var pullUp: CGFloat {
        max(vm.effectiveClosedNotchHeight - 4, 20)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            itemsScrollView
                // Nudges the item row up into the same overhead room the
                // header borrows — TrayItemView's own fixed height (icon +
                // label + its internal padding) is taller than what's left
                // after the header and outer padding otherwise, clipping the
                // selection outline at the bottom edge.
                .offset(y: -8)
        }
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .onChange(of: tvm.items.map(\.id)) { _, newIDs in
            if newIDs.isEmpty {
                withAnimation(.smooth(duration: 0.35)) {
                    vm.dismissCompactTrayPage()
                }
            } else {
                displayedItems = tvm.items
            }
        }
        .quickLookPresenter(using: quickLookService)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .frame(height: compactContentHeight, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    // Tray icon + item count on the leading edge, a trash "All" button on
    // the trailing edge that clears the whole tray in one tap.
    private var header: some View {
        GeometryReader { geo in
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(tvm.items.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Button {
                    selection.clear()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        TrayStateViewModel.shared.clear()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("All")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .disabled(tvm.items.isEmpty)
            }
            .offset(y: -pullUp)
            .frame(width: geo.size.width)
        }
        // Only the row's own (small) layout footprint is reserved — the
        // actual content overflows upward via the offset above.
        .frame(height: 8)
    }

    private var itemsScrollView: some View {
        ScrollView(.horizontal) {
            HStack(spacing: spacing) {
                ForEach(displayedItems) { item in
                    TrayItemView(item: item)
                        .environmentObject(quickLookService)
                        // Items pop in/out blurred, scaled and faded rather
                        // than just appearing, animated with the same spring
                        // used for add/remove.
                        .transition(.blurAndFade.combined(with: .scale).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: displayedItems.map(\.id))
        }
        .scrollIndicators(.never)
        .contentShape(Rectangle())
        .onTapGesture { selection.clear() }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            TrayStateViewModel.shared.load(providers)
            return true
        }
    }

    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }

        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }

        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }
}
