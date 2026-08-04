//
//  TraySelectionModel.swift
//  Knotch
//
//  Created by Alexander on 2025-09-26.
//

import Foundation
import Combine

private let _trayTypeAnchor: Bool = {
    _ = String(describing: TrayItem.self)
    return true
}()

@MainActor
final class TraySelectionModel: ObservableObject {
    static let shared = TraySelectionModel()

    @Published private(set) var selectedIDs: Set<UUID> = []

    // Anchor for shift-range selection
    private var lastAnchorID: UUID? = nil

    func isSelected(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    var hasSelection: Bool { !selectedIDs.isEmpty }

    var firstSelectedItem: TrayItem? {
        guard let firstID = selectedIDs.first else { return nil }
        return TrayStateViewModel.shared.items.first(where: { $0.id == firstID })
    }

    func selectedItems(in allItems: [TrayItem]) -> [TrayItem] {
        allItems.filter { selectedIDs.contains($0.id) }
    }

    func selectSingle(_ item: TrayItem) {
        selectedIDs = [item.id]
        lastAnchorID = item.id
    }

    func toggle(_ item: TrayItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
        lastAnchorID = item.id
    }

    func shiftSelect(to item: TrayItem, in allItems: [TrayItem]) {
        // Determine anchor
        let anchorID = lastAnchorID ?? selectedIDs.first ?? item.id
        guard let startIndex = allItems.firstIndex(where: { $0.id == anchorID }),
              let endIndex = allItems.firstIndex(where: { $0.id == item.id }) else {
            // Fallback to single select if indices not found
            return selectSingle(item)
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        let rangeIDs = allItems[lower...upper].map { $0.id }
        selectedIDs = Set(rangeIDs)
    }

    func clear() {
        selectedIDs.removeAll()
        lastAnchorID = nil
    }

    // Keep anchor sane if items array changed drastically (optional helper)
    func ensureValidAnchor(in allItems: [TrayItem]) {
        if let anchor = lastAnchorID, !allItems.contains(where: { $0.id == anchor }) {
            lastAnchorID = selectedIDs.first
        }
    }

    @Published private(set) var isDragging: Bool = false

    func beginDrag() {
        isDragging = true
    }

    func endDrag() {
        isDragging = false
    }
}
