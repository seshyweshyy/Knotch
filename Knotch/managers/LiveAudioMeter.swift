//
//  LiveAudioMeter.swift
//  Knotch
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
    static let bandCount = 5

    // Thread-safe amplitude storage written by IOProc, read by display link
    private let amplitudeBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: bandCount)

    // Published smoothed amplitudes, updated on main thread by display link
    @Published private(set) var amplitudes: [Float] = Array(repeating: 0, count: bandCount)

    // Smoothing coefficients
    private let attackCoeff: Float = 0.8
    private let decayCoeff: Float = 0.15
    private var smoothed: [Float] = Array(repeating: 0, count: bandCount)
    
    // Rolling per-band peak for self-normalizing loudness
    private var rollingPeak: [Float] = Array(repeating: 0.001, count: bandCount)
    private let peakDecay: Float = 0.996  // slow decay so quiet songs self-normalize

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

    private var retargetWork: DispatchWorkItem?

    func retarget(bundleID: String?) {
        retargetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard bundleID != self.targetBundleID else { return }
            self.targetBundleID = bundleID
            self.stop()
            guard let bundleID, !bundleID.isEmpty else { return }
            do {
                try self.start(bundleID: bundleID)
            } catch {
                NSLog("[LiveAudioMeter] start failed: \(error)")
            }
        }
        retargetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Tap lifecycle

    private func start(bundleID: String) throws {
        // 1. Find the AudioObjectID of the target process
        let processObjectID = try findProcessObjectID(bundleID: bundleID)

        // 2. Build CATapDescription targeting that process
        let tap = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tap.uuid = UUID()
        tap.muteBehavior = .unmuted
        tap.isPrivate = true
        tap.isExclusive = false

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
            [weak self] (inNow, inInputData, inInputTime, outOutputData, inOutputTime) in
            guard let self else { return }
            self.processInputData(inInputData, channelCount: channelCount)
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

    private func processInputData(_ inputData: UnsafePointer<AudioBufferList>?, channelCount: Int) {
        guard let inputData else { return }
        let abl = inputData.pointee
        guard abl.mNumberBuffers > 0 else { return }

        let buf = withUnsafePointer(to: abl.mBuffers) { $0.pointee }
        guard let dataPtr = buf.mData else { return }

        // Total float samples in buffer (interleaved channels)
        let totalSamples = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        guard totalSamples > 0 else { return }

        let ptr = dataPtr.assumingMemoryBound(to: Float.self)

        // Downmix interleaved stereo → mono by averaging channels
        let frameCount = totalSamples / max(channelCount, 1)
        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 2 {
            // Left + right average
            var scale: Float = 0.5
            vDSP_vasm(ptr, 2, ptr + 1, 2, &scale, &mono, 1, vDSP_Length(frameCount))
        } else {
            cblas_scopy(Int32(frameCount), ptr, Int32(channelCount), &mono, 1)
        }

        // FFT to get frequency content
        let fftSize = 1024
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Zero-pad or truncate mono buffer to fftSize
        var windowed = [Float](repeating: 0, count: fftSize)
        let copyCount = min(frameCount, fftSize)
        windowed.withUnsafeMutableBufferPointer { dst in
            mono.withUnsafeBufferPointer { src in
                cblas_scopy(Int32(copyCount), src.baseAddress!, 1, dst.baseAddress!, 1)
            }
        }

        // Apply Hann window to reduce spectral leakage
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack into split complex for FFT
        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)
        var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
        windowed.withUnsafeBytes { ptr in
            let floatPtr = ptr.bindMemory(to: DSPComplex.self)
            vDSP_ctoz(floatPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
        }
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // Compute magnitudes
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

        // Frequency bands with per-band gain to compensate for energy distribution
        // Low bands have high energy density (few bins, loud) → lower gain
        // High bands have low energy density (many bins, quiet) → higher gain
        let bandCount = Self.bandCount
        let binCount = fftSize / 2

        let bandBoundaries: [Int] = [
            0,
            Int(Float(binCount) * 0.05),   // bass      0–1.2kHz
            Int(Float(binCount) * 0.14),   // low-mid   1.2–3.4kHz
            Int(Float(binCount) * 0.30),   // mid       3.4–7.2kHz
            Int(Float(binCount) * 0.58),   // high-mid  7.2–13.9kHz
            binCount                        // high      13.9–24kHz
        ]

        // Per-band gain: low bands get less gain, high bands get more
        let bandGains: [Float] = [0.05, 1.0, 3.0, 3.8, 2.0]

        let bellCurve: [Float] = [0.7, 0.85, 1.0, 0.85, 0.7]
        var newAmplitudes = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let start = bandBoundaries[band]
            let end = bandBoundaries[band + 1]
            guard start < end else { continue }
            var rms: Float = 0
            vDSP_rmsqv(&magnitudes + start, 1, &rms, vDSP_Length(end - start))
            let normalized = rms / Float(end - start)
            let curved = powf(normalized, 0.45)
            newAmplitudes[band] = min(curved * bandGains[band] * bellCurve[band], 1.0)
        }

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
        var next = [Float](repeating: 0, count: Self.bandCount)
        for i in 0..<Self.bandCount {
            next[i] = amplitudeBuffer[i]
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in 0..<Self.bandCount {
                let raw = next[i]
                // Update rolling peak with slow decay
                self.rollingPeak[i] = max(self.rollingPeak[i] * self.peakDecay, raw, 0.001)
                // Normalize against rolling peak so quiet songs still animate fully
                let normalized = min(raw / self.rollingPeak[i], 1.0)
                // Attack/decay smoothing
                let coeff = normalized > self.smoothed[i] ? self.attackCoeff : self.decayCoeff
                self.smoothed[i] = self.smoothed[i] + coeff * (normalized - self.smoothed[i])
            }
            self.amplitudes = self.smoothed
        }
    }

    // MARK: - Process lookup
    
    func dumpProcessList() {
        guard let list = try? AudioObjectID.system.readProcessList() else {
            NSLog("[LiveAudioMeter] could not read process list")
            return
        }
        NSLog("[LiveAudioMeter] HAL process list (%d entries):", list.count)
        for objectID in list {
            let bundleID = objectID.readProcessBundleID() ?? "(nil)"
            NSLog("[LiveAudioMeter]   objectID=%u  bundleID=%@", objectID, bundleID)
        }
    }

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
