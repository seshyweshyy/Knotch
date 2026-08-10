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

// MARK: - FFT band extraction (ported from QuartzNotch)
//
// Replaces the earlier biquad filterbank. Runs entirely on the caller's
// processingQueue — no actor isolation. A 4096-point FFT with a Hann window,
// then per-band peak magnitude within a triangular weighting window (ramps
// up from `start` to `peak`, back down from `peak` to `end`), converted to
// dB and mapped against a fixed per-band min/max window, then raised to a
// per-band curve exponent. Each band's dB window and curve are calibrated
// individually — unlike a single shared window, this lets bands with very
// different natural energy (sub-bass vs. presence) each have headroom
// tuned to their own typical range.
private final class FFTProcessor {
    let fftSize = 4096
    private var fftSetup: FFTSetup?
    private var inputDataBuffer: [Float]
    private var magnitudesBuffer: [Float]
    private var magnitudesOutputBuffer: [Float]
    private var windowedBuffer: [Float]
    private var realPartsBuffer: [Float]
    private var imagPartsBuffer: [Float]
    private var hanningWindow: [Float]
    private var powerOutputBuffer: [Float]
    var sampleRate: Float = 48_000

    private var lastProcessTime: TimeInterval = 0
    let updateInterval: TimeInterval = 1.0 / 30.0

    private struct Band {
        let start: Float
        let peak: Float
        let end: Float
        let minDB: Float
        let maxDB: Float
        let curve: Float
    }

    private let bands: [Band] = [
        Band(start: 15,   peak: 35,   end: 90,    minDB: -45, maxDB: -1,  curve: 1.25),
        Band(start: 35,   peak: 100,  end: 160,   minDB: -38, maxDB: -2,  curve: 1.40),
        Band(start: 105,  peak: 300,  end: 520,   minDB: -42, maxDB: -8,  curve: 1.30),
        Band(start: 300,  peak: 620,  end: 1500,  minDB: -51, maxDB: -14, curve: 1.00),
        Band(start: 620,  peak: 1700, end: 4500,  minDB: -55, maxDB: -18, curve: 0.92),
        Band(start: 1200, peak: 4000, end: 12000, minDB: -50, maxDB: -20, curve: 1.25)
    ]

    init() {
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
        inputDataBuffer = Array(repeating: 0, count: fftSize)
        magnitudesBuffer = Array(repeating: 0, count: fftSize / 2)
        magnitudesOutputBuffer = Array(repeating: 0, count: fftSize / 2)
        windowedBuffer = Array(repeating: 0, count: fftSize)
        realPartsBuffer = Array(repeating: 0, count: fftSize / 2)
        imagPartsBuffer = Array(repeating: 0, count: fftSize / 2)
        hanningWindow = Array(repeating: 0, count: fftSize)
        powerOutputBuffer = Array(repeating: 0, count: bands.count)
        vDSP_hann_window(&hanningWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    // Returns nil if called too soon (rate-limited to 30fps)
    func process(samples: [Float]) -> [Float]? {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastProcessTime >= updateInterval else { return nil }
        lastProcessTime = now

        appendSamples(samples)

        vDSP_vmul(inputDataBuffer, 1, hanningWindow, 1, &windowedBuffer, 1, vDSP_Length(fftSize))

        for index in 0..<(fftSize / 2) {
            realPartsBuffer[index] = windowedBuffer[index * 2]
            imagPartsBuffer[index] = windowedBuffer[index * 2 + 1]
        }

        realPartsBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagPartsBuffer.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress,
                      let imagBase = imagPtr.baseAddress,
                      let setup = fftSetup else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudesBuffer, 1, vDSP_Length(fftSize / 2))
            }
        }

        magnitudesBuffer[0] = 0

        var magCount = Int32(fftSize / 2)
        vvsqrtf(&magnitudesOutputBuffer, magnitudesBuffer, &magCount)

        var scale = 2.0 / Float(fftSize)
        vDSP_vsmul(magnitudesOutputBuffer, 1, &scale, &magnitudesOutputBuffer, 1, vDSP_Length(fftSize / 2))

        for index in bands.indices {
            powerOutputBuffer[index] = getPower(for: bands[index], magnitudes: magnitudesOutputBuffer)
        }
        return powerOutputBuffer
    }

    private func appendSamples(_ samples: [Float]) {
        let count = min(samples.count, fftSize)
        guard count > 0 else { return }

        let sourceStart = samples.count - count
        if count >= fftSize {
            for index in 0..<fftSize {
                inputDataBuffer[index] = samples[sourceStart + index]
            }
            return
        }

        let preservedCount = fftSize - count
        inputDataBuffer.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memmove(base, base.advanced(by: count), preservedCount * MemoryLayout<Float>.size)
            for index in 0..<count {
                base[preservedCount + index] = samples[sourceStart + index]
            }
        }
    }

    private func getPower(for band: Band, magnitudes: [Float]) -> Float {
        let startBin = Int((band.start / sampleRate) * Float(fftSize))
        let endBin   = Int((band.end   / sampleRate) * Float(fftSize))

        let safeLower = max(1, startBin)
        let safeUpper = min(fftSize / 2 - 1, endBin)
        guard safeLower <= safeUpper else { return 0 }

        var maxMag: Float = 0
        var i = safeLower
        while i <= safeUpper {
            let f = Float(i) * sampleRate / Float(fftSize)
            let weight: Float
            if f <= band.peak {
                weight = max(0, (f - band.start) / max(1, band.peak - band.start))
            } else {
                weight = max(0, (band.end - f) / max(1, band.end - band.peak))
            }
            let mag = magnitudes[i] * weight
            if mag > maxMag { maxMag = mag }
            i += 1
        }

        let db = 20 * log10(max(maxMag, 1e-6))
        var normalized = (db - band.minDB) / (band.maxDB - band.minDB)
        normalized = max(0.0, min(1.0, normalized))
        return pow(normalized, band.curve)
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
    // Set when processBlock writes a fresh FFT frame, cleared once publishAmplitudes
    // consumes it — keeps the smoothing step from re-applying itself to the same
    // stale target on 60Hz ticks that land between 30Hz FFT updates.
    private var hasNewAmplitudeData = false

    // Published smoothed amplitudes, updated on main thread by display link
    @Published private(set) var amplitudes: [Float] = Array(repeating: 0, count: bandCount)

    // Smoothing coefficients — matches QuartzNotch's applySmoothing: fast
    // attack, slower decay, with bands 3/4 (mid, upper-mid) getting an even
    // faster attack so vocal/snare content snaps up quicker than the rest.
    private let attackCoeff: Float = 0.85
    private let fastAttackCoeff: Float = 0.91
    private let decayCoeff: Float = 0.62
    private var smoothed: [Float] = Array(repeating: 0, count: bandCount)

    // Processes the FFT off the real-time IOProc thread — see
    // processInputData's comment for why.
    private let processingQueue = DispatchQueue(label: "com.knotch.liveaudiometer.processing", qos: .utility)
    private let fftProcessor = FFTProcessor()

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

    // Fixed-size scratch buffer reused every callback so the real-time audio
    // thread never allocates. Typical HAL block sizes (512–4096 samples) are
    // well under this ceiling.
    private static let maxBlockSamples = 8192
    private let monoScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: maxBlockSamples)

    private init() {
        amplitudeBuffer.initialize(repeating: 0)
    }

    deinit {
        stop()
        amplitudeBuffer.deallocate()
        monoScratch.deallocate()
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

        // 1. Find every AudioObjectID belonging to the target process. Browsers
        // (Chrome, Safari, etc.) run each tab/site in its own sandboxed helper
        // process, and CoreAudio can list several of those under the same
        // bundle ID — the one actually producing sound isn't necessarily the
        // first entry. Mixing down all of them means we tap whichever one is
        // playing, regardless of how many other tabs/helpers are idle.
        let processObjectIDs = try findProcessObjectIDs(bundleID: bundleID)

        // 2. Build CATapDescription targeting those processes
        let tap = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
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

        fftProcessor.sampleRate = Float(sampleRate)

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
    // Only the downmix happens here. The biquad filterbank + dB conversion
    // used to run inline in this callback, but that's real work on a thread
    // with a hard deadline — a missed deadline here means audible dropouts
    // in system audio, not just a visual glitch. So this callback does the
    // cheapest possible thing (downmix to mono, copy it out of the
    // HAL-owned buffer) and hands the copy to processingQueue, off the
    // real-time thread, for the actual filtering.

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

        // Copy out before handing off — monoScratch gets overwritten next callback
        let block = Array(UnsafeBufferPointer(start: monoScratch.baseAddress, count: frameCount))
        processingQueue.async { [weak self] in
            self?.processBlock(block)
        }
    }

    // Runs on processingQueue — off the real-time audio thread. Rate-limited
    // to 30fps internally by FFTProcessor, matching QuartzNotch — process()
    // returns nil (skip this block) if called before that interval elapses.
    private func processBlock(_ mono: [Float]) {
        guard let newAmplitudes = fftProcessor.process(samples: mono) else { return }

        os_unfair_lock_lock(&amplitudeLock)
        for i in 0..<Self.bandCount {
            amplitudeBuffer[i] = newAmplitudes[i]
        }
        hasNewAmplitudeData = true
        os_unfair_lock_unlock(&amplitudeLock)
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
        guard hasNewAmplitudeData else {
            os_unfair_lock_unlock(&amplitudeLock)
            return
        }
        hasNewAmplitudeData = false
        for i in 0..<Self.bandCount {
            next[i] = amplitudeBuffer[i]
        }
        os_unfair_lock_unlock(&amplitudeLock)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in 0..<Self.bandCount {
                // amplitudeBuffer is already dB-normalized per band by
                // FFTProcessor — this is just attack/decay envelope smoothing.
                let normalized = next[i]
                let attack = (i == 3 || i == 4) ? self.fastAttackCoeff : self.attackCoeff
                let coeff = normalized > self.smoothed[i] ? attack : self.decayCoeff
                self.smoothed[i] = self.smoothed[i] + coeff * (normalized - self.smoothed[i])
            }
            self.amplitudes = self.smoothed
        }
    }

    // MARK: - Process lookup

    // Browsers report Now Playing info under their main bundle ID (e.g.
    // "com.google.Chrome"), but the actual sound is produced by a sandboxed
    // helper process with its own, distinct bundle ID — "com.google.Chrome.helper"
    // is the one that actually outputs audio, while "com.google.Chrome" itself
    // never does. Matching only exact equality taps permanent silence.
    // Chromium-family browsers (Chrome, Edge, Brave, ...) all name these
    // helpers as dot-suffixed children of the main bundle ID, so widen the
    // match to include them.
    private func findProcessObjectIDs(bundleID: String) throws -> [AudioObjectID] {
        let processList = try AudioObjectID.system.readProcessList()
        let matches = processList.filter {
            guard let candidate = $0.readProcessBundleID() else { return false }
            return candidate == bundleID || candidate.hasPrefix(bundleID + ".")
        }
        guard !matches.isEmpty else { throw MeterError.processNotFound(bundleID) }
        return matches
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
