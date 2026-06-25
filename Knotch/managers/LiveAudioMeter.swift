//
//  LiveAudioMeter.swift
//  Knotch
//
//  Created by seshyweshyy
//
//  Raw HAL tap approach — no AVAudioEngine. Avoids the format-negotiation
//  failures from our previous CATapDescription + AVAudioEngine attempt.
//

import AudioToolbox
import Accelerate
import Combine
import Foundation

@available(macOS 14.2, *)
final class LiveAudioMeter {
    static let shared = LiveAudioMeter()

    // Number of amplitude values published (matches AudioSpectrum bar count)
    static let bandCount = 6

    // Thread-safe amplitude storage written by IOProc, read by display link
    private let amplitudeBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: bandCount)

    // Published smoothed amplitudes, updated on main thread by display link
    @Published private(set) var amplitudes: [Float] = Array(repeating: 0, count: bandCount)

    // Smoothing coefficients
    private let attackCoeff: Float = 0.6
    private let decayCoeff: Float = 0.12
    private var smoothed: [Float] = Array(repeating: 0, count: bandCount)

    // CoreAudio objects
    private var processTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    // Display link for main-thread amplitude publishing
    private var displayLink: CVDisplayLink?

    // Target bundle ID (e.g. "com.spotify.client")
    private var targetBundleID: String?

    private init() {
        amplitudeBuffer.initialize(repeating: 0)
    }

    deinit {
        stop()
        amplitudeBuffer.deallocate()
    }

    // MARK: - Public API

    func retarget(bundleID: String?) {
        guard bundleID != targetBundleID else { return }
        targetBundleID = bundleID
        stop()
        guard let bundleID, !bundleID.isEmpty else { return }
        do {
            try start(bundleID: bundleID)
        } catch {
            NSLog("[LiveAudioMeter] start failed: \(error)")
        }
    }

    // MARK: - Tap lifecycle

    private func start(bundleID: String) throws {
        // 1. Find the AudioObjectID of the target process
        let processObjectID = try findProcessObjectID(bundleID: bundleID)

        // 2. Build CATapDescription targeting that process
        let tap = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tap.uuid = UUID()
        tap.muteBehavior = .unmuted
        tap.privateTap = true
        tap.exclusive = false

        // 3. Create the process tap
        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapErr = AudioHardwareCreateProcessTap(tap, &tapID)
        guard tapErr == noErr, tapID != kAudioObjectUnknown else {
            throw MeterError.tapCreationFailed(tapErr)
        }
        processTapID = tapID

        // 4. Get the tap's UID (needed for aggregate device sub-tap entry)
        let tapUID = tap.uuid.uuidString

        // 5. Get the default output device UID to anchor the aggregate
        let defaultOutputID = try AudioObjectID.system.readDefaultSystemOutputDevice()
        let outputUID = try defaultOutputID.readDeviceUID()

        // 6. Build aggregate device dict — tap only, no sub-devices
        //    (adding the output device as a sub-device causes routing loops)
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "KnotchMeter-\(bundleID)",
            kAudioAggregateDeviceUIDKey: "knotch.meter.\(bundleID).\(tapUID)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMasterSubDeviceKey: outputUID,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]

        var aggID: AudioDeviceID = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggID)
        guard aggErr == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = kAudioObjectUnknown
            throw MeterError.aggregateDeviceFailed(aggErr)
        }
        aggregateDeviceID = aggID

        // 7. Read the format the tap actually delivers
        let tapASBD = try tapID.readAudioTapStreamBasicDescription()
        let sampleRate = tapASBD.mSampleRate > 0 ? tapASBD.mSampleRate : 48000
        let channelCount = tapASBD.mChannelsPerFrame > 0 ? Int(tapASBD.mChannelsPerFrame) : 2

        NSLog("[LiveAudioMeter] tap format: %.0f Hz, %d ch", sampleRate, channelCount)

        // 8. Register IOProc — raw HAL callback, no AVAudioEngine
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil) {
            [weak self] _, _, inputData, _, _ in
            guard let self, let inputData else { return }
            self.processInputData(inputData, channelCount: channelCount)
        }
        guard procErr == noErr else {
            teardownCoreAudio()
            throw MeterError.ioProcFailed(procErr)
        }
        _ = selfPtr // silence unused warning

        // 9. Start the device
        let startErr = AudioDeviceStart(aggID, ioProcID)
        guard startErr == noErr else {
            teardownCoreAudio()
            throw MeterError.deviceStartFailed(startErr)
        }

        NSLog("[LiveAudioMeter] tap started for %@", bundleID)

        // 10. Start display link for main-thread publishing
        startDisplayLink()
    }

    private func stop() {
        stopDisplayLink()
        teardownCoreAudio()
        // Zero out amplitudes
        amplitudeBuffer.update(repeating: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.smoothed = Array(repeating: 0, count: Self.bandCount)
            self.amplitudes = self.smoothed
        }
    }

    private func teardownCoreAudio() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let procID = ioProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if processTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = kAudioObjectUnknown
        }
    }

    // MARK: - IOProc audio processing (realtime audio thread)

    private func processInputData(_ inputData: UnsafePointer<AudioBufferList>, channelCount: Int) {
        let abl = inputData.pointee
        let bufferCount = Int(abl.mNumberBuffers)
        guard bufferCount > 0 else { return }

        // Treat each buffer as one channel (interleaved or non-interleaved)
        // Distribute into bandCount slots using RMS per segment
        let bandCount = Self.bandCount
        var newAmplitudes = [Float](repeating: 0, count: bandCount)

        // Use first buffer (interleaved stereo or mono)
        let buf = withUnsafePointer(to: abl.mBuffers) { ptr in
            ptr.pointee
        }
        guard let dataPtr = buf.mData else { return }
        let frameCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }

        let samples = UnsafeBufferPointer<Float>(
            start: dataPtr.assumingMemoryBound(to: Float.self),
            count: frameCount
        )

        // Split frame array into bandCount equal segments and RMS each
        let samplesPerBand = max(1, frameCount / bandCount)
        for band in 0..<bandCount {
            let start = band * samplesPerBand
            let end = min(start + samplesPerBand, frameCount)
            guard start < end else { continue }
            var rms: Float = 0
            vDSP_rmsqv(samples.baseAddress! + start, 1, &rms, vDSP_Length(end - start))
            newAmplitudes[band] = min(rms * 4.0, 1.0) // scale + clamp
        }

        // Write atomically to shared buffer
        for i in 0..<bandCount {
            amplitudeBuffer[i] = newAmplitudes[i]
        }
    }

    // MARK: - Display link (main thread publish)

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }

        CVDisplayLinkSetOutputHandler(dl) { [weak self] _, _, _, _, _ in
            self?.publishAmplitudes()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(dl)
        displayLink = dl
    }

    private func stopDisplayLink() {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
            displayLink = nil
        }
    }

    private func publishAmplitudes() {
        // Read from atomic buffer, apply attack/decay smoothing, publish on main
        var next = [Float](repeating: 0, count: Self.bandCount)
        for i in 0..<Self.bandCount {
            next[i] = amplitudeBuffer[i]
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in 0..<Self.bandCount {
                let target = next[i]
                let coeff = target > self.smoothed[i] ? self.attackCoeff : self.decayCoeff
                self.smoothed[i] = self.smoothed[i] + coeff * (target - self.smoothed[i])
            }
            self.amplitudes = self.smoothed
        }
    }

    // MARK: - Process lookup

    private func findProcessObjectID(bundleID: String) throws -> AudioObjectID {
        let processList = try AudioObjectID.system.readProcessList()
        for objectID in processList {
            if objectID.readProcessBundleID() == bundleID {
                return objectID
            }
        }
        throw MeterError.processNotFound(bundleID)
    }

    // MARK: - Errors

    enum MeterError: Error, CustomStringConvertible {
        case processNotFound(String)
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case deviceStartFailed(OSStatus)

        var description: String {
            switch self {
            case .processNotFound(let id): return "Process not found for bundle ID: \(id)"
            case .tapCreationFailed(let s): return "AudioHardwareCreateProcessTap failed: \(s)"
            case .aggregateDeviceFailed(let s): return "AudioHardwareCreateAggregateDevice failed: \(s)"
            case .ioProcFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed: \(s)"
            case .deviceStartFailed(let s): return "AudioDeviceStart failed: \(s)"
            }
        }
    }
}

// MARK: - CoreAudioUtils extensions (subset from insidegui/AudioCap)

private extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "readProcessList size: \(err)" }
        var value = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw "readProcessList data: \(err)" }
        return value
    }

    func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else { throw "readDefaultOutputDevice: \(err)" }
        return value
    }

    func readDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else { throw "readDeviceUID: \(err)" }
        return value as String
    }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else { throw "readTapFormat: \(err)" }
        return value
    }

    func readProcessBundleID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else { return nil }
        let s = value as String
        return s.isEmpty ? nil : s
    }
}

extension String: @retroactive Error {}