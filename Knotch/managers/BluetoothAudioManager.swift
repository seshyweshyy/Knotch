//
//  BluetoothAudioManager.swift
//  Knotch
//

import CoreAudio
import Defaults
import Foundation
import IOKit
import IOBluetooth
import CoreBluetooth

final class BluetoothAudioManager {
    static let shared = BluetoothAudioManager()

    private var knownDeviceIDs: Set<AudioDeviceID> = []
    private let queue = DispatchQueue(label: "com.knotch.bluetooth", qos: .utility)

    private init() {
        queue.async { [weak self] in
            guard let self else { return }
            self.knownDeviceIDs = Set(self.currentDeviceIDs())
            self.startListening()
        }
    }

    private func startListening() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue
        ) { [weak self] _, _ in
            self?.devicesChanged()
        }
    }

    private func devicesChanged() {
        guard Defaults[.showBluetoothDeviceConnections] else { return }

        let current = Set(currentDeviceIDs())
        let added = current.subtracting(knownDeviceIDs)
        knownDeviceIDs = current

        for deviceID in added {
            guard let name = deviceName(for: deviceID) else { continue }
            let transport = transportType(for: deviceID)
            guard transport == kAudioDeviceTransportTypeBluetooth ||
                  transport == kAudioDeviceTransportTypeBluetoothLE else { continue }
            guard deviceHasOutputChannels(deviceID) else { continue }

            let device = AudioOutputDevice(id: deviceID, name: name, transportType: transport)
            let icon = device.iconName
            let address = bluetoothDeviceAddress(forName: name)
            let batteryLevel = bluetoothBatteryLevel(address: address, name: name)
            print("[BT] '\(name)' connected — battery: \(batteryLevel)%")

            DispatchQueue.main.async {
                KnotchViewCoordinator.shared.toggleBluetoothSneakPeek(
                    deviceName: name,
                    icon: icon,
                    batteryLevel: batteryLevel
                )
            }

            // Registry/cache/system_profiler/pmset all missed — try a live
            // BLE GATT read as a last resort and update the HUD if it
            // resolves in time.
            if batteryLevel < 0 {
                refreshBatteryLevelViaBLE(address: address, name: name)
            }
        }
    }

    /// Looks up the battery percentage of a paired Bluetooth device. Checks
    /// the IORegistry (what Control Center reads for Apple accessories),
    /// then the com.apple.Bluetooth device cache, then falls back to
    /// `pmset -g accps` for third-party accessories. Returns 0–100, or -1
    /// if unavailable. Safe to call synchronously — we're already on `queue`.
    private func bluetoothBatteryLevel(address: String?, name: String) -> Int {
        let target = normalizeBluetoothName(name)
        guard !target.isEmpty else { return -1 }

        if let level = batteryLevelFromRegistry(address: address, name: target) { return level }
        if let level = batteryLevelFromDeviceCache(address: address, name: target) { return level }
        if let level = batteryLevelFromSystemProfiler(address: address, name: target) { return level }
        if let level = batteryLevelFromPmset(matching: target) { return level }

        print("[BT] '\(name)' — no tier resolved a battery level")
        return -1
    }

    /// Reads battery via `system_profiler SPBluetoothDataType -json` — the
    /// same source Bluetooth Preferences and Control Center use. Runs as a
    /// separate signed subprocess, so it works without Full Disk Access.
    private func batteryLevelFromSystemProfiler(address: String?, name target: String) -> Int? {
        let process = Process()
        process.launchPath = "/usr/sbin/system_profiler"
        process.arguments = ["SPBluetoothDataType", "-json"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["SPBluetoothDataType"] as? [[String: Any]],
              let root = entries.first,
              let connectedList = root["device_connected"] as? [[String: [String: Any]]] else {
            return nil
        }

        let normalizedAddress = address.map(normalizeBluetoothAddress)

        for deviceGroup in connectedList {
            for (rawName, payload) in deviceGroup {
                let candidateAddress = (payload["device_address"] as? String)
                    ?? (payload["device_mac_address"] as? String)

                // When an address was resolved, it must match exactly — devices
                // can appear twice under the same name (e.g. a rotating private
                // BLE address alongside the real classic Bluetooth address), so
                // falling back to name-only here risks reading the wrong entry.
                let matches: Bool
                if let normalizedAddress {
                    matches = candidateAddress.map { normalizeBluetoothAddress($0) == normalizedAddress } ?? false
                } else {
                    matches = namesFuzzyMatch(normalizeBluetoothName(rawName), target)
                }

                guard matches else { continue }

                if let percent = extractSystemProfilerBatteryPercentage(from: payload) {
                    return percent
                }
            }
        }
        return nil
    }

    private func extractSystemProfilerBatteryPercentage(from payload: [String: Any]) -> Int? {
        let keys = [
            "device_batteryLevelCase", "device_batteryLevelLeft", "device_batteryLevelRight",
            "device_batteryLevelMain", "device_batteryLevel", "device_batteryLevelCombined",
            "device_batteryPercentCombined", "Battery Level"
        ]
        let values = keys.compactMap { payload[$0] }.compactMap(convertBatteryValue)
        return values.max().map { min(max($0, 0), 100) }
    }

    private func convertBatteryValue(_ value: Any) -> Int? {
        if let number = value as? Int { return number == 1 ? 100 : number }
        if let number = value as? Double { return number <= 1.0 ? Int(number * 100) : Int(number) }
        if let string = value as? String {
            let trimmed = string.replacingOccurrences(of: "%", with: "")
            if let d = Double(trimmed) { return d <= 1.0 ? Int(d * 100) : Int(d) }
        }
        return nil
    }

    private func normalizeBluetoothName(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    /// Names like "AirPods Pro" (IOBluetooth) and "John's AirPods Pro"
    /// (CoreAudio) refer to the same device but never match exactly —
    /// possessive prefixes, punctuation, and pluralization differ by source.
    /// Substring-contains on the normalized strings handles that.
    private func namesFuzzyMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Resolves the Bluetooth address for a connected device by name, via
    /// IOBluetooth's paired-devices list. Only returned when exactly one
    /// connected device matches the name — this is what disambiguates two
    /// identically-named accessories (e.g. two stock "AirPods Pro") in the
    /// lookups below. If it's ambiguous, callers fall back to name-only
    /// matching, same as before.
    private func bluetoothDeviceAddress(forName name: String) -> String? {
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return nil
        }
        let connected = pairedDevices.filter { $0.isConnected() }
        let target = normalizeBluetoothName(name)
        let matches = connected.filter { device in
            guard let deviceName = device.name else { return false }
            return namesFuzzyMatch(target, normalizeBluetoothName(deviceName))
        }
        return matches.count == 1 ? matches.first?.addressString : nil
    }

    private func normalizeBluetoothAddress(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func batteryLevelFromRegistry(address: String?, name target: String) -> Int? {
        var iterator = io_iterator_t()
        let matchingDict = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let normalizedAddress = address.map(normalizeBluetoothAddress)
        let addressKeys = ["DeviceAddress", "SerialNumber", "BD_ADDR"]
        let nameKeys = ["Product", "ProductName", "DeviceName", "Name"]

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            let matchesAddress = normalizedAddress.map { normAddr in
                addressKeys.contains { key in
                    guard let value = registryStringValue(forKey: key, entry: entry) else { return false }
                    return normalizeBluetoothAddress(value) == normAddr
                }
            } ?? false

            let matchesName = nameKeys.contains { key in
                guard let value = registryStringValue(forKey: key, entry: entry) else { return false }
                return namesFuzzyMatch(normalizeBluetoothName(value), target)
            }

            guard matchesAddress || matchesName else { continue }

            if let percent = IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                return min(max(percent, 0), 100)
            }
        }
        return nil
    }

    private func registryStringValue(forKey key: String, entry: io_object_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let string = value as? String { return string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private func batteryLevelFromDeviceCache(address: String?, name target: String) -> Int? {
        guard let preferences = UserDefaults(suiteName: "/Library/Preferences/com.apple.Bluetooth"),
              let deviceCache = preferences.object(forKey: "DeviceCache") as? [String: Any] else {
            return nil
        }

        let percentKeys = [
            "BatteryPercent", "BatteryPercentCase", "BatteryPercentLeft",
            "BatteryPercentRight", "BatteryPercentSingle", "BatteryPercentCombined"
        ]
        let addressKeys = ["DeviceAddress", "Address", "BD_ADDR", "SerialNumber"]
        let normalizedAddress = address.map(normalizeBluetoothAddress)

        for (key, value) in deviceCache {
            guard let payload = value as? [String: Any] else { continue }

            let candidateName = (payload["Name"] as? String) ?? (payload["DeviceName"] as? String)

            let matchesAddress = normalizedAddress.map { normAddr in
                normalizeBluetoothAddress(key) == normAddr ||
                addressKeys.contains { addrKey in
                    guard let value = payload[addrKey] as? String else { return false }
                    return normalizeBluetoothAddress(value) == normAddr
                }
            } ?? false

            let matchesName = candidateName.map { namesFuzzyMatch(normalizeBluetoothName($0), target) } ?? false

            guard matchesAddress || matchesName else { continue }

            let levels = percentKeys.compactMap { payload[$0] as? Int }
            if let best = levels.max() {
                return min(max(best, 0), 100)
            }
        }
        return nil
    }

    /// Last resort for third-party accessories that only expose battery via
    /// the external accessory power source API.
    private func batteryLevelFromPmset(matching target: String) -> Int? {
        let process = Process()
        process.launchPath = "/usr/bin/pmset"
        process.arguments = ["-g", "accps"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty,
              let output = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"^\s*-\s*(.+?)\s*(?:\(.+?\))?\s+(\d+)\s*%"#, options: [.anchorsMatchLines]) else {
            return nil
        }

        let nsOutput = output as NSString
        var bestMatch: Int?
        regex.enumerateMatches(in: output, range: NSRange(location: 0, length: nsOutput.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let rawName = nsOutput.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard namesFuzzyMatch(normalizeBluetoothName(rawName), target),
                  let level = Int(nsOutput.substring(with: match.range(at: 2))) else { return }
        }
        return bestMatch
    }

    /// Resolves the CBPeripheral identifier for a paired device via the same
    /// CoreBluetoothCache that macOS itself uses to map classic Bluetooth
    /// pairings to their BLE identity.
    private func coreBluetoothPeripheralUUID(address: String?, name target: String) -> UUID? {
        guard let preferences = UserDefaults(suiteName: "/Library/Preferences/com.apple.Bluetooth"),
              let cache = preferences.object(forKey: "CoreBluetoothCache") as? [String: [String: Any]] else {
            return nil
        }

        let normalizedAddress = address.map(normalizeBluetoothAddress)
        let addressKeys = ["DeviceAddress", "Address", "BD_ADDR"]
        let nameKeys = ["Name", "DeviceName", "ProductName"]

        for (uuidString, payload) in cache {
            guard let uuid = UUID(uuidString: uuidString) else { continue }

            if let normalizedAddress,
               addressKeys.contains(where: { key in
                   guard let value = payload[key] as? String else { return false }
                   return normalizeBluetoothAddress(value) == normalizedAddress
               }) {
                return uuid
            }

            if nameKeys.contains(where: { key in
                guard let value = payload[key] as? String else { return false }
                return normalizeBluetoothName(value) == target
            }) {
                return uuid
            }
        }
        return nil
    }

    private let liveBatteryReader = BluetoothLEBatteryReader()

    /// Last resort for devices that expose the standard BLE Battery Service
    /// (0x180F) but didn't show up in the registry, device cache, or pmset.
    /// Connects live and reads the Battery Level characteristic directly.
    /// Async — has to establish a BLE connection — so it updates the
    /// already-shown HUD in place if a value arrives in time.
    private func refreshBatteryLevelViaBLE(address: String?, name: String) {
        let target = normalizeBluetoothName(name)
        guard let uuid = coreBluetoothPeripheralUUID(address: address, name: target) else { return }

        liveBatteryReader.fetchBatteryLevel(for: uuid) { level in
            guard let level else { return }
            let clamped = min(max(level, 0), 100)
            Task { @MainActor in
                guard KnotchViewCoordinator.shared.sneakPeek.show,
                      KnotchViewCoordinator.shared.sneakPeek.type == .bluetoothAudio,
                      KnotchViewCoordinator.shared.sneakPeek.deviceName == name else { return }
                KnotchViewCoordinator.shared.sneakPeek.value = CGFloat(clamped) / 100.0
            }
        }
    }

    // MARK: - CoreAudio helpers

    private func currentDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { namePtr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, namePtr)
        }
        guard status == noErr, let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var type: UInt32 = kAudioDeviceTransportTypeUnknown
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &type)
        return type
    }

    private func deviceHasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}

// MARK: - Live BLE Battery Service Reader

/// Connects to a specific peripheral and reads the standard GATT Battery
/// Level characteristic (0x2A19) from the Battery Service (0x180F).
/// One-shot: a fresh instance's `fetchBatteryLevel` completes with a value
/// or nil, then tears the connection back down.
private final class BluetoothLEBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingUUID: UUID?
    private var completion: ((Int?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func fetchBatteryLevel(for uuid: UUID, timeout: TimeInterval = 2.0, completion: @escaping (Int?) -> Void) {
        self.completion = completion
        scheduleTimeout(timeout)

        if central.state == .poweredOn {
            connect(uuid)
        } else {
            // Not ready yet — try again once centralManagerDidUpdateState fires,
            // otherwise the timeout above will finish with nil.
            pendingUUID = uuid
        }
    }

    private func connect(_ uuid: UUID) {
        guard let match = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            finish(with: nil)
            return
        }
        peripheral = match
        match.delegate = self
        central.connect(match, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, let uuid = pendingUUID {
            pendingUUID = nil
            connect(uuid)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(with: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryServiceUUID }) else {
            finish(with: nil)
            return
        }
        peripheral.discoverCharacteristics([Self.batteryLevelCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.batteryLevelCharacteristicUUID }) else {
            finish(with: nil)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let byte = characteristic.value?.first else {
            finish(with: nil)
            return
        }
        finish(with: Int(byte))
    }

    private func scheduleTimeout(_ timeout: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in self?.finish(with: nil) }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func finish(with level: Int?) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        let completion = self.completion
        self.completion = nil
        completion?(level)
    }
}
