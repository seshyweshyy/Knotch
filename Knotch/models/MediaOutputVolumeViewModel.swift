//
//  MediaOutputVolumeViewModel.swift
//  Knotch
//

import AudioToolbox
import CoreAudio
import Combine
import Foundation

final class MediaOutputVolumeViewModel: ObservableObject {
    @Published var level: Float = 0.5
    @Published var isMuted: Bool = false

    init() {
        syncFromSystem()
        listenForChanges()
    }

    func setVolume(_ value: Float) {
        level = max(0, min(1, value))
        if level > 0 { isMuted = false }
        writeVolume(level)
    }

    func toggleMute() {
        isMuted.toggle()
        setSystemMute(isMuted)
    }

    // MARK: - Private

    private func syncFromSystem() {
        level = readVolume()
        isMuted = readMute()
    }

    private func listenForChanges() {
        // Re-sync whenever the default output device changes
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.syncFromSystem()
        }

        // Re-sync on volume or mute changes on the current device
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return }

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.syncFromSystem()
        }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.syncFromSystem()
        }
    }

    private func defaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func readVolume() -> Float {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return 0.5 }

        // VirtualMainVolume works for all device types including AirPods/Bluetooth
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = Float32(0.5)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return volume
    }

    private func writeVolume(_ value: Float) {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var v = Float32(max(0, min(1, value)))
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private func readMute() -> Bool {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        return muted != 0
    }

    private func setSystemMute(_ muted: Bool) {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            // Device doesn't support hardware mute (common with Bluetooth) —
            // fake it by setting volume to 0 / restoring it
            writeVolume(muted ? 0 : level)
            return
        }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
