//
//  DisplaySleepPreventer.swift
//  Knotch
//

import IOKit.pwr_mgt

final class DisplaySleepPreventer {
    static let shared = DisplaySleepPreventer()
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func acquire() {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Knotch: album art expanded on lock screen" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            held = true
        }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }
}
