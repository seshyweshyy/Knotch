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
import os

/// Marks short windows during which our own CoreAudio hardware reconfiguration
/// (tearing down/creating the aggregate device + tap in LiveAudioMeter) is
/// expected to trigger a spurious camera disconnect/reconnect on Apple Silicon.
/// WebcamManager checks this to avoid tearing down the capture session for
/// bounces we caused ourselves, rather than a real unplug.
enum AudioHardwareReconfig {
    private static let lock = NSLock()
    private static var _isLikelyBounce = false
    private static var resetWorkItem: DispatchWorkItem?

    static var isLikelyBounce: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isLikelyBounce
    }

    static func markPending(for duration: TimeInterval = 1.5) {
        lock.lock()
        _isLikelyBounce = true
        lock.unlock()

        resetWorkItem?.cancel()
        let work = DispatchWorkItem {
            lock.lock()
            _isLikelyBounce = false
            lock.unlock()
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

@available(macOS 14.2, *)
final class LiveAudioMeter {
    static let shared = LiveAudioMeter()

    // Number of amplitude values published (matches AudioSpectrum bar count)
    static let bandCount = 6

    // Amplitude storage written by IOProc, read by display link.
    // Guarded by amplitudeLock — os_unfair_lock is cheap enough for these
    // tiny, uncontended critical sections and avoids a torn/racy read.
    private let amplitudeBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: bandCount)
    private var amplitudeLock = os_unfair_lock_s()

    // Published smoothed amplitudes, updated on main thread by display link
    @Published private(set) var amplitudes: [Float] = Array(repeating: 0, count: bandCount)

    // Smoothing coefficients
    private let attackCoeff: Float = 0.95
    private let decayCoeff: Float = 0.35
    private var smoothed: [Float] = Array(repeating: 0, count: bandCount)
    
    // Rolling per-band peak for self-normalizing loudness
    private var rollingPeak: [Float] = Array(repeating: 0.001, count: bandCount)
    private let peakDecay: Float = 0.996  // slow decay so quiet songs self-normalize

    // CoreAudio objects
    private var processTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    // Timer for main-thread amplitude publishing (replaces deprecated CVDisplayLink,
    // which requires anchoring to a specific NSView/NSWindow/NSScreen we don't have
    // as a singleton audio processor)
    private var displayTimer: DispatchSourceTimer?

    // Target bundle ID (e.g. "com.spotify.client")
    private var targetBundleID: String?

    // MARK: - Biquad filterbank state (persistent IIR delay lines — must
    // survive across IOProc callbacks, unlike the FFT setup this replaced)

    // Center/cutoff freq + Q per band. Bands 0–3 and their gains are the
    // hand-tuned values from the 5-bar layout, left untouched. The old top
    // band (highpass at 13.9k) is narrowed into band 4 to make room for a
    // new band 5 above it — band 4/5 gains are first-pass guesses and will
    // likely need the same by-ear tuning the first four already got.
    private static let bandFilters: [(kind: BiquadKind, freq: Double, q: Double)] = [
        (.lowPass,  1200,  0.707),
        (.bandPass, 2019,  0.92),
        (.bandPass, 4949,  1.30),
        (.bandPass, 9999,  1.49),
        (.bandPass, 15818, 3.86),
        (.highPass, 18000, 0.707)
    ]
    private static let bandGains: [Float] = [0.6, 1.0, 1.0, 1.5, 1.0, 0.5]

    private var biquadSetups: [vDSP_biquad_Setup?] = Array(repeating: nil, count: bandCount)
    private var biquadDelays: [[Float]] = Array(repeating: [Float](repeating: 0, count: 4), count: bandCount)

    // Fixed-size scratch buffers reused every callback so the real-time
    // audio thread never allocates. Typical HAL block sizes (512–4096
    // samples) are well under this ceiling.
    private static let maxBlockSamples = 8192
    private let monoScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: maxBlockSamples)
    private let filteredScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: maxBlockSamples)

    private init() {
        amplitudeBuffer.initialize(repeating: 0)
    }

    deinit {
        stop()
        amplitudeBuffer.deallocate()
        monoScratch.deallocate()
        filteredScratch.deallocate()
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
        AudioHardwareReconfig.markPending()

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

        setupBiquadFilters(sampleRate: sampleRate)

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
        os_unfair_lock_lock(&amplitudeLock)
        amplitudeBuffer.update(repeating: 0)
        os_unfair_lock_unlock(&amplitudeLock)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.smoothed = Array(repeating: 0, count: Self.bandCount)
            self.amplitudes = self.smoothed
        }
    }

    private func teardownCoreAudio() {
        AudioHardwareReconfig.markPending()
        teardownBiquadFilters()

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
    //
    // Runs a 5-band biquad filterbank (Accelerate vDSP_biquad) instead of a
    // full FFT. An FFT recomputed every callback — including tearing down
    // and rebuilding its setup object each time — is far more work than this
    // thread's deadline calls for; a handful of IIR sections + RMS gets the
    // same "loudness per band" signal for a fraction of the cost, which
    // matters here because a missed deadline means audible dropouts in
    // system audio, not just a visual glitch.

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

        // Downmix interleaved stereo → mono by averaging channels, into a
        // preallocated scratch buffer (no per-callback heap allocation)
        let frameCount = min(totalSamples / max(channelCount, 1), Self.maxBlockSamples)
        guard frameCount > 0 else { return }
        if channelCount == 2 {
            var scale: Float = 0.5
            vDSP_vasm(ptr, 2, ptr + 1, 2, &scale, monoScratch.baseAddress!, 1, vDSP_Length(frameCount))
        } else {
            vDSP_mmov(ptr, monoScratch.baseAddress!, vDSP_Length(frameCount), 1, vDSP_Length(channelCount), 1)
        }

        var newAmplitudes = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            guard let setup = biquadSetups[band] else { continue }
            biquadDelays[band].withUnsafeMutableBufferPointer { delayPtr in
                vDSP_biquad(setup, delayPtr.baseAddress!, monoScratch.baseAddress!, 1, filteredScratch.baseAddress!, 1, vDSP_Length(frameCount))
            }
            var rms: Float = 0
            vDSP_rmsqv(filteredScratch.baseAddress!, 1, &rms, vDSP_Length(frameCount))
            if !rms.isFinite { rms = 0 }
            // 0.9, not 0.45: the old FFT path curved RMS-of-squared-magnitude
            // (a power-like, amplitude² quantity), so its 0.45 exponent was
            // effectively amplitude^0.9 — nearly linear, preserving dynamic
            // range. This path curves the raw-amplitude RMS directly, so it
            // needs the same effective exponent to avoid over-compressing
            // quiet-vs-loud swings into a narrow band near the top.
            let curved = powf(rms, 0.9)
            // No ceiling here — rms is bounded by the PCM range (≤1) so this
            // can't blow up. Clamping to 1.0 flattened loud moments to a
            // shared value, which then locked rollingPeak near 1.0 downstream
            // and killed the bar-to-bar dynamics.
            newAmplitudes[band] = curved * Self.bandGains[band]
        }

        os_unfair_lock_lock(&amplitudeLock)
        for i in 0..<Self.bandCount {
            amplitudeBuffer[i] = newAmplitudes[i]
        }
        os_unfair_lock_unlock(&amplitudeLock)
    }

    // MARK: - Biquad filterbank setup

    private enum BiquadKind {
        case lowPass, bandPass, highPass
    }

    private func biquadCoefficients(kind: BiquadKind, freq: Double, q: Double, sampleRate: Double) -> [Double] {
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let sinw = sin(w0)
        let cosw = cos(w0)
        let alpha = sinw / (2.0 * q)

        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosw
        let a2 = 1.0 - alpha
        let b0: Double
        let b1: Double
        let b2: Double
        switch kind {
        case .lowPass:
            b0 = (1.0 - cosw) * 0.5; b1 = 1.0 - cosw; b2 = b0
        case .highPass:
            b0 = (1.0 + cosw) * 0.5; b1 = -(1.0 + cosw); b2 = b0
        case .bandPass:
            b0 = alpha; b1 = 0.0; b2 = -alpha
        }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    private func setupBiquadFilters(sampleRate: Double) {
        teardownBiquadFilters()
        for (i, band) in Self.bandFilters.enumerated() {
            let coeffs = biquadCoefficients(kind: band.kind, freq: band.freq, q: band.q, sampleRate: sampleRate)
            biquadSetups[i] = vDSP_biquad_CreateSetup(coeffs, 1)
            biquadDelays[i] = [Float](repeating: 0, count: 4)
        }
    }

    private func teardownBiquadFilters() {
        for i in 0..<biquadSetups.count {
            if let setup = biquadSetups[i] {
                vDSP_biquad_DestroySetup(setup)
                biquadSetups[i] = nil
            }
        }
    }

    // MARK: - Display link (main thread publish)

    private func startDisplayLink() {
        guard displayTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            self?.publishAmplitudes()
        }
        timer.resume()
        displayTimer = timer
    }

    private func stopDisplayLink() {
        displayTimer?.cancel()
        displayTimer = nil
    }

    private func publishAmplitudes() {
        var next = [Float](repeating: 0, count: Self.bandCount)
        os_unfair_lock_lock(&amplitudeLock)
        for i in 0..<Self.bandCount {
            next[i] = amplitudeBuffer[i]
        }
        os_unfair_lock_unlock(&amplitudeLock)
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
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &value) { valuePtr -> OSStatus in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, valuePtr)
        }
        guard err == noErr, let cfValue = value?.takeRetainedValue() else {
            throw "readDeviceUID: \(err)"
        }
        return cfValue as String
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
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &value) { valuePtr -> OSStatus in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, valuePtr)
        }
        guard err == noErr, let cfValue = value?.takeRetainedValue() else { return nil }
        let s = cfValue as String
        return s.isEmpty ? nil : s
    }
}

extension String: @retroactive Error {}
