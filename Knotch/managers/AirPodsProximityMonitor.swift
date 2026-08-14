//
//  AirPodsProximityMonitor.swift
//  Knotch
//

import CoreBluetooth
import Foundation

/// Passively listens for Apple's undocumented "Proximity Pairing" BLE
/// advertisement (manufacturer ID 0x004C, message type 0x07) that AirPods
/// broadcast continuously while connected to any nearby device. Unlike
/// BluetoothAudioManager's battery tiers, this doesn't require pairing —
/// it's a raw advertisement scan, and the payload carries per-bud in-ear
/// status alongside per-bud battery, which no paired-device cache exposes.
/// Byte layout reverse-engineered by the community (furiousMAC/continuity,
/// LibrePods) — undocumented and unversioned, so Apple could change it
/// without notice; this stays best-effort.
final class AirPodsProximityMonitor: NSObject, ObservableObject, CBCentralManagerDelegate {
    static let shared = AirPodsProximityMonitor()

    /// Set only when exactly one bud is in-ear and its model has a
    /// left/right SF Symbol pair to show — nil when both are worn, both are
    /// out, the model has no per-bud icon, or nothing's been heard recently.
    @Published private(set) var activeBud: ActiveBud?

    /// A general battery reading straight from the broadcast, independent of
    /// which bud (if any) is confidently "the worn one" — the lower of the
    /// two buds when both report, since that's the one that'll run out
    /// first. Used as a fallback so the lock-screen pill can show *some*
    /// percentage even when BluetoothAudioManager's paired-device tiers
    /// come up empty and no single bud is in ear.
    @Published private(set) var combinedBatteryLevel: Int?

    struct ActiveBud: Equatable {
        let iconName: String
        let batteryLevel: Int?
    }

    private var central: CBCentralManager?
    private var staleTimer: Timer?

    // The advertisement is unencrypted and broadcast to anyone nearby, not
    // just this Mac's paired AirPods, so a strong-signal threshold is the
    // only proxy for "this is probably the user's own pair" — a neighbor's
    // identical model sitting further away should read weaker than this.
    // Loose enough to tolerate normal RSSI fade (closed-lid clamshell mode,
    // AirPods in a pocket, etc.) without needing line-of-sight proximity.
    private static let minimumRSSI = -80
    // Battery percentage barely moves minute to minute, so it's worth
    // holding the last known reading well past any single missed broadcast
    // window rather than flickering the pill back to the device name —
    // that flicker was worse UX than a slightly stale number.
    private static let staleAfter: TimeInterval = 90

    private override init() {
        super.init()
    }

    func startScanning() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stopScanning() {
        central?.stopScan()
        central = nil
        staleTimer?.invalidate()
        staleTimer = nil
        activeBud = nil
        combinedBatteryLevel = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // allowDuplicates is required — AirPods re-advertise every ~1s with a
        // rotating encrypted tail, and without it CoreBluetooth coalesces
        // those into a single stale sighting.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard RSSI.intValue >= Self.minimumRSSI,
              let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let parsed = Self.parseProximityPairing(manufacturerData) else { return }
        apply(parsed)
    }

    private func apply(_ parsed: ParsedStatus) {
        scheduleStaleCheck()

        combinedBatteryLevel = [parsed.leftBattery, parsed.rightBattery].compactMap { $0 }.min()

        guard parsed.leftInEar != parsed.rightInEar else {
            activeBud = nil
            return
        }
        activeBud = ActiveBud(
            iconName: Self.budIconName(modelId: parsed.modelId, left: parsed.leftInEar),
            batteryLevel: parsed.leftInEar ? parsed.leftBattery : parsed.rightBattery
        )
    }

    private func scheduleStaleCheck() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: Self.staleAfter, repeats: false) { [weak self] _ in
            self?.activeBud = nil
            self?.combinedBatteryLevel = nil
        }
    }

    // MARK: - Parsing

    private struct ParsedStatus {
        let modelId: Int
        let leftInEar: Bool
        let rightInEar: Bool
        let leftBattery: Int?
        let rightBattery: Int?
    }

    /// `CBAdvertisementDataManufacturerDataKey` includes the 2-byte company
    /// ID up front, then Apple's own [type][length] envelope, then the
    /// message fields:
    /// [0-1] company ID (0x4C,0x00) [2] type=0x07 [3] length [4] prefix=0x01
    /// [5-6] model (big-endian) [7] status [8] battery nibbles ...
    private static func parseProximityPairing(_ data: Data) -> ParsedStatus? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9,
              bytes[0] == 0x4C, bytes[1] == 0x00,
              bytes[2] == 0x07,
              bytes[4] == 0x01
        else { return nil }

        let modelId = (Int(bytes[5]) << 8) | Int(bytes[6])
        let status = Int(bytes[7])
        let battery = Int(bytes[8])

        // Bit 5 of the status byte says which physical bud is "primary" (the
        // one whose data comes first in the battery byte); bit 6 says
        // whether that primary bud is in the case. XOR of the two tells us
        // whether the in-ear bits at 0x02/0x08 need swapping to map onto
        // actual left/right, same for the battery nibbles via `isFlipped`.
        let primaryLeft = (status >> 5) & 0x01 == 1
        let thisInCase = (status >> 6) & 0x01 == 1
        let earBitsSwapped = primaryLeft != thisInCase
        let isFlipped = !primaryLeft

        let leftInEar = earBitsSwapped ? (status & 0x08) != 0 : (status & 0x02) != 0
        let rightInEar = earBitsSwapped ? (status & 0x02) != 0 : (status & 0x08) != 0

        let highNibble = (battery >> 4) & 0x0F
        let lowNibble = battery & 0x0F
        let leftNibble = isFlipped ? highNibble : lowNibble
        let rightNibble = isFlipped ? lowNibble : highNibble

        return ParsedStatus(
            modelId: modelId,
            leftInEar: leftInEar,
            rightInEar: rightInEar,
            leftBattery: decodeBatteryNibble(leftNibble),
            rightBattery: decodeBatteryNibble(rightNibble)
        )
    }

    private static func decodeBatteryNibble(_ nibble: Int) -> Int? {
        switch nibble {
        case 0x0...0x9: return nibble * 10
        case 0xA...0xE: return 100
        default: return nil // 0xF = disconnected/unknown
        }
    }

    /// Only two left/right SF Symbol pairs exist on this OS, so every model
    /// maps to whichever one it's visually closer to: any Pro generation
    /// gets the Pro glyph, everything else (regular AirPods, AirPods 3/4,
    /// Max) gets the gen4 glyph as the closest available stand-in.
    private static func budIconName(modelId: Int, left: Bool) -> String {
        let proModels: Set<Int> = [0x0E20, 0x1420, 0x2420, 0x2720] // Pro, Pro 2, Pro 2 (USB-C), Pro 3
        if proModels.contains(modelId) { return left ? "airpodpro.left" : "airpodpro.right" }
        return left ? "airpods.gen4.left" : "airpods.gen4.right"
    }
}
