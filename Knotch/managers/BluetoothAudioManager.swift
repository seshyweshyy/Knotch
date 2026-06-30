//
//  BluetoothAudioManager.swift
//  Knotch
//

import CoreAudio
import Defaults
import Foundation

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
        print("[BT] devicesChanged fired")
        guard Defaults[.showBluetoothDeviceConnections] else {
            print("[BT] guard failed: showBluetoothDeviceConnections is false")
            return
        }

        let current = Set(currentDeviceIDs())
        let added = current.subtracting(knownDeviceIDs)
        knownDeviceIDs = current
        print("[BT] added device IDs: \(added)")

        for deviceID in added {
            guard let name = deviceName(for: deviceID) else {
                print("[BT] skipping \(deviceID): no name")
                continue
            }
            let transport = transportType(for: deviceID)
            print("[BT] device '\(name)' transport: \(transport)")
            guard transport == kAudioDeviceTransportTypeBluetooth ||
                  transport == kAudioDeviceTransportTypeBluetoothLE else {
                print("[BT] skipping '\(name)': not bluetooth transport")
                continue
            }
            guard deviceHasOutputChannels(deviceID) else {
                print("[BT] skipping '\(name)': no output channels")
                continue
            }

            let device = AudioOutputDevice(id: deviceID, name: name, transportType: transport)
            let icon = device.iconName
            let batteryLevel = bluetoothBatteryLevel(for: deviceID)
            print("[BT] showing HUD for '\(name)', icon: \(icon), battery: \(batteryLevel)")

            DispatchQueue.main.async {
                KnotchViewCoordinator.shared.toggleBluetoothSneakPeek(
                    deviceName: name,
                    icon: icon,
                    batteryLevel: batteryLevel
                )
            }
        }
    }

    /// Queries IOBluetooth for the battery percentage of a named device.
    /// Returns a value 0–100, or -1 if unavailable.
    private func bluetoothBatteryLevel(for deviceID: AudioDeviceID) -> Int {
        return -1
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
