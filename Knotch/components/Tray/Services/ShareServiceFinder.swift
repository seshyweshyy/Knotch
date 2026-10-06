//
//  ShareServiceFinder.swift
//  Knotch
//
//  Created by Alexander on 2025-10-06.
//

import Cocoa

@MainActor
final class ShareServiceFinder: NSObject, @preconcurrency NSSharingServicePickerDelegate {

    /// AppKit sharing services are main-thread objects but predate Sendable.
    /// This value never leaves MainActor; the box only bridges the checked
    /// continuation's generic `sending` requirement.
    private struct ServiceList: @unchecked Sendable {
        let services: [NSSharingService]
    }

    private var onServicesCaptured: (([NSSharingService]) -> Void)?

    /// Returns share services asynchronously without blocking the UI
    func findApplicableServices(for items: [Any], timeout: TimeInterval = 2.0) async -> [NSSharingService] {

        let dummyView = NSView(frame: .zero)
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self

        let result: ServiceList = await withCheckedContinuation { continuation in
            var didResume = false

            // Capture services callback
            onServicesCaptured = { services in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: ServiceList(services: services))
            }

            picker.show(relativeTo: dummyView.bounds, of: dummyView, preferredEdge: .minY)


            // Timeout task
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !didResume else { return }
                didResume = true
                print("Warning: timed out waiting for sharing services")
                continuation.resume(returning: ServiceList(services: []))
            }
        }
        return result.services
    }

    // MARK: NSSharingServicePickerDelegate

    func sharingServicePicker(_ picker: NSSharingServicePicker,
                              sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        onServicesCaptured?(proposed)
        return proposed
    }
}
