//
//  MusicSlotConfigurationView.swift
//  Knotch
//

import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// What's currently being dragged, tracked locally so the origin slot can dim in place
/// and the drop target can be resolved once the drag actually lands.
private enum MusicControlDragSource: Equatable {
    case slot(Int)
    case palette(MusicControlButton)
}

/// A slot's content, identified by the control it holds (or its index, if empty) rather
/// than by its position — so when two slots swap, ForEach recognizes it as the same
/// item moving to a new position and animates the move, instead of two cells silently
/// swapping content in place.
private struct SlotItem: Identifiable {
    let id: String
    let index: Int
    let control: MusicControlButton
}

struct MusicSlotConfigurationView: View {
    @Default(.musicControlSlots) private var musicControlSlots
    @ObservedObject private var musicManager = MusicManager.shared
    @Namespace private var slotNamespace
    @State private var draggingSource: MusicControlDragSource?

    private let fixedSlotCount: Int = 5
    private var moveSpring: Animation { .spring(response: 0.42, dampingFraction: 0.68) }

    /// Controls not currently occupying a slot — the only ones offered in the palette
    /// or in a slot's "assign" menu, so a control is never listed twice.
    private var availableOptions: [MusicControlButton] {
        MusicControlButton.pickerOptions.filter { !musicControlSlots.contains($0) }
    }

    private var slotItems: [SlotItem] {
        (0..<fixedSlotCount).map { index in
            let control = slotValue(at: index)
            let id = control == .none ? "empty-\(index)" : "control-\(control.rawValue)"
            return SlotItem(id: id, index: index, control: control)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            layoutPreview
            Divider()
            palette

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    withAnimation(moveSpring) {
                        musicControlSlots = MusicControlButton.defaultLayout
                    }
                }
                .settingsSubtleGlassButton()
            }
        }
        .onAppear {
            ensureSlotCapacity(fixedSlotCount)
        }
        // Catch-all: if a drag is released anywhere in here that isn't a slot or the
        // palette's own remove target (e.g. the gap between them), still clear the
        // dragging state so the source cell doesn't stay stuck looking picked-up.
        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { _ in
            draggingSource = nil
            return false
        }
    }

    private var layoutPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layout Preview")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Drag to rearrange, or right-click a slot")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(slotItems) { item in
                    SlotCell(
                        index: item.index,
                        control: item.control,
                        namespace: slotNamespace,
                        availableOptions: availableOptions,
                        draggingSource: $draggingSource,
                        iconColor: previewIconColor(for:),
                        onAssign: { control in place(control, at: item.index) },
                        onClear: { clear(item.index) },
                        onDropped: { completeDrag(at: item.index) }
                    )
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag a control onto a slot, or click one below to add it")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 12) {
                ForEach(availableOptions, id: \.self) { control in
                    PaletteCell(
                        control: control,
                        namespace: slotNamespace,
                        draggingSource: $draggingSource,
                        onSelect: { assignToFirstEmptySlot(control) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.visible)
        // Drag a slot's control down into the palette to remove it from the layout.
        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { _ in
            guard case .slot(let index)? = draggingSource else { return false }
            clear(index)
            draggingSource = nil
            return true
        }
    }

    private func previewIconColor(for slot: MusicControlButton) -> Color {
        switch slot {
        case .shuffle:
            return musicManager.isShuffled ? .effectiveAccent : .primary
        case .repeatMode:
            return musicManager.repeatMode != .off ? .effectiveAccent : .primary
        case .favorite:
            return musicManager.isFavoriteTrack ? .effectiveAccent : .primary
        case .playPause:
            return .primary
        default:
            return .primary
        }
    }

    private func ensureSlotCapacity(_ target: Int) {
        guard target > musicControlSlots.count else { return }
        let missing = target - musicControlSlots.count
        musicControlSlots.append(contentsOf: Array(repeating: .none, count: missing))
    }

    private func slotValue(at index: Int) -> MusicControlButton {
        guard musicControlSlots.indices.contains(index) else { return .none }
        return musicControlSlots[index]
    }

    private func ensureCount(_ slots: inout [MusicControlButton], _ target: Int) {
        guard slots.count < target else { return }
        slots.append(contentsOf: Array(repeating: .none, count: target - slots.count))
    }

    /// Places `control` at `index`, clearing any other slot it already occupies so a
    /// control never appears twice in the layout.
    private func place(_ control: MusicControlButton, at index: Int) {
        guard control != .none else { clear(index); return }
        var slots = musicControlSlots
        ensureCount(&slots, fixedSlotCount)
        if let existing = slots.firstIndex(of: control), existing != index {
            slots[existing] = .none
        }
        slots[index] = control
        withAnimation(moveSpring) {
            musicControlSlots = slots
        }
    }

    private func clear(_ index: Int) {
        guard musicControlSlots.indices.contains(index) else { return }
        var slots = musicControlSlots
        slots[index] = .none
        withAnimation(moveSpring) {
            musicControlSlots = slots
        }
    }

    private func swapSlots(_ from: Int, _ to: Int) {
        guard from != to else { return }
        var slots = musicControlSlots
        ensureCount(&slots, fixedSlotCount)
        guard slots.indices.contains(from), slots.indices.contains(to) else { return }
        slots.swapAt(from, to)
        withAnimation(moveSpring) {
            musicControlSlots = slots
        }
    }

    private func assignToFirstEmptySlot(_ control: MusicControlButton) {
        if let idx = musicControlSlots.firstIndex(of: .none) {
            place(control, at: idx)
        } else {
            place(control, at: 0)
        }
    }

    /// Applies the pending drag to `index` once it's actually dropped there.
    private func completeDrag(at index: Int) {
        guard let source = draggingSource else { return }
        switch source {
        case .slot(let from):
            swapSlots(from, index)
        case .palette(let control):
            place(control, at: index)
        }
        draggingSource = nil
    }
}

/// A single slot in the layout preview bar. The dragged control is the real slot's
/// content — no separately-authored ghost view — lifted with a shadow while it's held.
/// Hovering a slot just highlights it; the swap/placement applies once actually dropped.
/// The origin slot dims in place for the whole drag so it never reads as a duplicate.
private struct SlotCell: View {
    let index: Int
    let control: MusicControlButton
    let namespace: Namespace.ID
    let availableOptions: [MusicControlButton]
    @Binding var draggingSource: MusicControlDragSource?
    let iconColor: (MusicControlButton) -> Color
    let onAssign: (MusicControlButton) -> Void
    let onClear: () -> Void
    let onDropped: () -> Void

    @State private var isHovering = false
    @State private var isTargeted = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    private var targetSpring: Animation { .spring(response: 0.32, dampingFraction: 0.55) }
    private var isBeingDragged: Bool { draggingSource == .slot(index) }

    var body: some View {
        Group {
            if control == .none {
                emptyContent
                    .contextMenu {
                        ForEach(availableOptions, id: \.self) { option in
                            Button {
                                onAssign(option)
                            } label: {
                                Label(option.label, systemImage: option.iconName)
                            }
                        }
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                filledContent
                    .matchedGeometryEffect(id: "control-\(control.rawValue)", in: namespace)
                    .opacity(isBeingDragged ? 0.35 : 1)
                    .onDrag {
                        DispatchQueue.main.async { draggingSource = .slot(index) }
                        return NSItemProvider(object: NSString(string: "slot"))
                    } preview: {
                        liftedPreview
                    }
                    .contextMenu {
                        if !availableOptions.isEmpty {
                            Menu("Replace With") {
                                ForEach(availableOptions, id: \.self) { option in
                                    Button {
                                        onAssign(option)
                                    } label: {
                                        Label(option.label, systemImage: option.iconName)
                                    }
                                }
                            }
                        }
                        Button(role: .destructive, action: onClear) {
                            Label("Remove from Layout", systemImage: "minus.circle")
                        }
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: 44, height: 44)
        .onDrop(of: [UTType.plainText.identifier], isTargeted: $isTargeted) { _ in
            onDropped()
            return true
        }
        .onHover { isHovering = $0 }
        .onChange(of: draggingSource) { _, newValue in
            // AppKit doesn't reliably fire the hover-exit event once a drag starts, so a
            // cell can be left looking "picked up" after the drag ends elsewhere. Force
            // the hover state to clear whenever any drag concludes.
            if newValue == nil { isHovering = false }
        }
    }

    private var emptyContent: some View {
        ZStack {
            shape.fill(Color(NSColor.controlBackgroundColor))
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 44, height: 44)
        .contentShape(shape)
        .overlay(targetRing)
        .shadow(color: isTargeted ? Color.accentColor.opacity(0.3) : .clear, radius: 4)
        .animation(targetSpring, value: isTargeted)
    }

    private var filledContent: some View {
        ZStack {
            shape.fill(Color(NSColor.controlBackgroundColor))
            icon(size: control.prefersLargeScale ? 18 : 15)
        }
        .frame(width: 44, height: 44)
        .contentShape(shape)
        .overlay(targetRing)
        .overlay(alignment: .topTrailing) {
            if isHovering && !isTargeted {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color(NSColor.controlBackgroundColor), Color.secondary)
                        .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                }
                .buttonStyle(.plain)
                .offset(x: 7, y: -7)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .shadow(color: isTargeted ? Color.accentColor.opacity(0.3) : .clear, radius: 4)
        .scaleEffect(isHovering && !isTargeted ? 1.05 : 1.0)
        .animation(targetSpring, value: isTargeted)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovering)
    }

    private var liftedPreview: some View {
        ZStack {
            shape.fill(Color(NSColor.controlBackgroundColor))
            icon(size: control.prefersLargeScale ? 18 : 15)
        }
        .frame(width: 48, height: 48)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    private var targetRing: some View {
        shape.strokeBorder(Color.accentColor, lineWidth: isTargeted ? 2 : 0)
    }

    private func icon(size: CGFloat) -> some View {
        Image(systemName: control.iconName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(iconColor(control))
            .frame(width: 28, height: 28)
    }
}

/// A control available to place into the layout. Disappears from the grid once it's
/// placed in a slot — it flies there via a shared matchedGeometryEffect — and reappears
/// here if removed.
private struct PaletteCell: View {
    let control: MusicControlButton
    let namespace: Namespace.ID
    @Binding var draggingSource: MusicControlDragSource?
    let onSelect: () -> Void

    @State private var isHovering = false
    private var isBeingDragged: Bool { draggingSource == .palette(control) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isHovering ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
                    )

                Image(systemName: control.iconName)
                    .font(.system(size: control.prefersLargeScale ? 18 : 15, weight: .medium))
                    .foregroundStyle(Color.primary)
            }
            .frame(width: 44, height: 44)
            .matchedGeometryEffect(id: "control-\(control.rawValue)", in: namespace)
            .opacity(isBeingDragged ? 0.35 : 1)
            .scaleEffect(isHovering ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture(perform: onSelect)
            .onDrag {
                DispatchQueue.main.async { draggingSource = .palette(control) }
                return NSItemProvider(object: NSString(string: "control"))
            } preview: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                    Image(systemName: control.iconName)
                        .font(.system(size: control.prefersLargeScale ? 18 : 15, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            }
            .onHover { isHovering = $0 }
            .onChange(of: draggingSource) { _, newValue in
                if newValue == nil { isHovering = false }
            }

            Text(control.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 76)
                .multilineTextAlignment(.center)
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}
