//
//  AudioRouteManager.swift
//  Knotch
//

import AppKit
import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32

    var iconName: String {
        let n = name.lowercased()

        // Headphones/earbuds (check before speaker brands)
        if n.contains("airpods") { return "airpodspro" }
        // Built-in speakers are always this Mac, so use the notch/no-notch
        // silhouette that actually matches its chassis rather than the
        // generic "laptopcomputer" glyph.
        if n.contains("macbook") { return Self.builtInMacHasNotch ? "macbook" : "macbook.gen1" }
        if n.contains("headphone") || n.contains("headset") { return "headphones" }
        if n.contains("earbuds") || n.contains("earphones") { return "earbuds" }
        if n.contains("homepod") { return "homepod.fill" }

        // Beats: disambiguate speakers vs headphones
        if n.contains("beats") {
            // Beats Pill, Beats Studio Pro (speaker), vs Beats Solo, Beats Fit, etc.
            let beatsSpeakers = ["pill", "studio pro"]
            return beatsSpeakers.contains(where: n.contains) ? "speaker.wave.2" : "headphones"
        }

        // Known speaker brands/models — always a speaker regardless of transport
        let speakerKeywords = [
            "jbl", "bose soundlink", "bose revolve", "bose home",
            "sonos", "marshall", "ultimate ears", "ue ", "ue_",
            "charge", "flip", "pulse", "clip", "link", "boom",
            "wonderboom", "megaboom", "hyperboom", "roam",
            "sony srs", "sony lspx", "anker soundcore",
            "soundcore", "tribit", "harman", "onyx",
            "speaker", "portable speaker"
        ]
        if speakerKeywords.contains(where: { n.contains($0) }) { return "hifispeaker.fill" }

        // Known headphone brands — always headphones
        let headphoneKeywords = [
            "sony wh", "sony wf", "sony wi",
            "bose quietcomfort", "bose qc", "bose nc",
            "jabra", "sennheiser", "audio-technica",
            "plantronics", "poly ", "anker soundbuds",
            "galaxy buds", "pixel buds", "nothing ear",
            "skullcandy", "jlab"
        ]
        if headphoneKeywords.contains(where: { n.contains($0) }) { return "headphones" }

        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones" // unknown BT device: safer default is headphones
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire:
            return "cable.connector"
        case kAudioDeviceTransportTypeBuiltIn:
            return n.contains("display") ? "tv" : "speaker.wave.2"
        default:
            return "speaker.wave.2"
        }
    }

    // Whether this Mac's built-in display has a physical camera notch —
    // true for MacBook Pro (2021+) and MacBook Air (2022+), false for every
    // older MacBook. Looked up once since the chassis can't change at runtime.
    private static let builtInMacHasNotch: Bool = {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(screenNumber) != 0
            else { continue }
            return screen.safeAreaInsets.top > 0
        }
        return false
    }()
}

final class AudioRouteManager: ObservableObject {
    static let shared = AudioRouteManager()

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var activeDeviceID: AudioDeviceID = 0

    private let queue = DispatchQueue(label: "com.Knotch.audio-route", qos: .userInitiated)

    private init() {
        refreshDevices()
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshDevices()
        }
    }

    var activeDevice: AudioOutputDevice? {
        devices.first { $0.id == activeDeviceID }
    }

    func refreshDevices() {
        queue.async { [weak self] in
            guard let self else { return }
            let defaultID = self.fetchDefaultOutputDevice()
            let infos = self.fetchOutputDeviceIDs().compactMap(self.makeDeviceInfo)
            let sorted = infos.sorted {
                if $0.id == defaultID { return true }
                if $1.id == defaultID { return false }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                self.activeDeviceID = defaultID
                self.devices = sorted
            }
        }
    }

    func select(device: AudioOutputDevice) {
        queue.async { [weak self] in
            self?.setDefaultOutputDevice(device.id)
        }
    }

    // MARK: - Private

    private func fetchDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    private func fetchOutputDeviceIDs() -> [AudioDeviceID] {
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

    private func makeDeviceInfo(for deviceID: AudioDeviceID) -> AudioOutputDevice? {
        guard deviceHasOutputChannels(deviceID) else { return nil }
        guard let name = deviceName(for: deviceID) else { return nil }
        let transport = transportType(for: deviceID)
        return AudioOutputDevice(id: deviceID, name: name, transportType: transport)
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

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var target = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &target)
        if status == noErr {
            DispatchQueue.main.async { [weak self] in
                self?.activeDeviceID = deviceID
            }
            refreshDevices()
        }
    }
}
