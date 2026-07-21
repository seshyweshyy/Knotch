//
//  MusicVisualizer.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

/// Single source of truth for the bar look. Every call site frames
/// AudioSpectrumView using `recommendedFrameSize` below instead of its own
/// hardcoded numbers, so changing these here is the only edit needed.
///
/// To resize the whole waveform, change `scale` — it multiplies bar
/// width/spacing/height together instead of hand-balancing them separately.
/// `barCount` is discrete and stays untouched by scale.
enum AudioSpectrum {
    static let scale: CGFloat = 1.15
    private static let baseBarWidth: CGFloat = 2.1
    private static let baseSpacing: CGFloat = 0.9
    private static let baseTotalHeight: CGFloat = 16

    // Rounded to whole points so every bar's edges land on the same pixel
    // grid regardless of its x position in the HStack — a fractional width
    // (e.g. 2.205pt) can round to a different physical pixel count per bar
    // depending on subpixel position, making bars look inconsistently thick.
    static var barWidth: CGFloat { (baseBarWidth * scale).rounded() }
    static let barCount = 6
    static var spacing: CGFloat { (baseSpacing * scale).rounded() }
    static var totalHeight: CGFloat { baseTotalHeight * scale }

    // Per-bar sensitivity exponent applied at render time, separate from
    // LiveAudioMeter's fixed dB calibration. `pow(level, boost)` with
    // boost < 1 lifts quiet signal more while leaving loud signal nearly
    // unchanged; boost == 1 is linear. Keeping this here (not baked into the
    // DSP) means "how snappy does this bar look" can be tuned independently
    // of "how loud is this frequency band, in absolute terms".
    //
    // Matches QuartzNotch's `(i == 2 || i == 5) ? 0.60 : (i >= 2 ? 0.72 : 1.0)`:
    // bass bands (0, 1) stay linear, bands 2 and 5 get the biggest lift,
    // bands 3/4 a moderate one.
    static let boosts: [Float] = [1.0, 1.0, 0.60, 0.72, 0.72, 0.60]

    // Exact bar-row footprint at rest
    static var contentSize: CGSize {
        CGSize(width: CGFloat(barCount) * (barWidth + spacing), height: totalHeight)
    }

    // Content size plus headroom for the spring animation's overshoot, so
    // loud transients don't get clipped by a container sized to the resting
    // bar height.
    static var recommendedFrameSize: CGSize {
        CGSize(width: contentSize.width + 4, height: contentSize.height + 4)
    }

    // liveMix (0...1) crossfades between real audio data and the decorative
    // simulated wave instead of hard-switching, so toggling live waveform
    // on/off eases the bars from one source to the other rather than
    // dropping to idle and snapping to whichever is newly selected.
    // 0 == fully simulated, 1 == fully live.
    static func barHeight(_ index: Int, isPlaying: Bool, amplitudes: [Float], liveMix: CGFloat, simulatedTime: Double) -> CGFloat {
        let minHeight = barWidth
        guard isPlaying else { return minHeight }

        let liveLevel: Float = index < amplitudes.count && index < boosts.count
            ? powf(max(0, amplitudes[index]), boosts[index])
            : 0
        let simLevel = simulatedLevel(index, time: simulatedTime)
        let level = Float(liveMix) * liveLevel + Float(1 - liveMix) * simLevel

        let maxExtra = totalHeight - minHeight
        return minHeight + CGFloat(min(1, level)) * maxExtra
    }

    // Decorative fallback wave for when live audio tapping is off — ported
    // from QuartzNotch's synthetic idle animation: three summed sine waves
    // per bar plus a shared "groove" and an occasional tremor burst, each bar
    // with its own frequency/phase so they don't move in lockstep.
    private struct SimWaveParam {
        let f1: Double, a1: Double
        let f2: Double, a2: Double
        let f3: Double, a3: Double
        let center: Double
        let phase: Double
    }

    private static let simWaveParams: [SimWaveParam] = [
        SimWaveParam(f1: 9.1, a1: 0.20, f2: 13.9, a2: 0.13, f3: 19.3, a3: 0.08, center: 0.37, phase: 0.0),
        SimWaveParam(f1: 5.4, a1: 0.11, f2: 8.4,  a2: 0.06, f3: 13.1, a3: 0.07, center: 0.18, phase: 1.8),
        SimWaveParam(f1: 6.8, a1: 0.14, f2: 10.5, a2: 0.08, f3: 16.7, a3: 0.09, center: 0.22, phase: 3.5),
        SimWaveParam(f1: 9.5, a1: 0.20, f2: 15.1, a2: 0.11, f3: 11.3, a3: 0.10, center: 0.33, phase: 0.4),
        SimWaveParam(f1: 9.5, a1: 0.18, f2: 12.3, a2: 0.12, f3: 17.9, a3: 0.09, center: 0.33, phase: 1.1),
        SimWaveParam(f1: 7.0, a1: 0.20, f2: 11.2, a2: 0.11, f3: 14.3, a3: 0.09, center: 0.30, phase: 5.1),
    ]

    // Slows the whole wave uniformly (applied to every sine term below,
    // tremor included) without needing to retune each frequency separately.
    private static let simSpeedFactor: Double = 0.65

    private static func simulatedLevel(_ index: Int, time rawTime: Double) -> Float {
        guard index < simWaveParams.count else { return 0 }
        let time = rawTime * simSpeedFactor
        let p = simWaveParams[index]
        let shared = sin(time * 6.1) * 0.08 + sin(time * 10.1) * 0.05
        // Tremor is the jittery part on purpose — a fast, burst-modulated
        // wobble layered over the smoother main waves. Cut its amplitude and
        // narrowed its frequency range so it reads as a subtle shimmer
        // instead of a shake.
        let tremorEnv = abs(sin(time * 0.7 + p.phase * 0.4)) * abs(sin(time * 1.3 + p.phase * 0.7)) * 0.04
        let tremorFreq = 12.0 + abs(sin(time * 0.3 + p.phase * 0.5)) * 8.0
        let tremor = sin(time * tremorFreq + p.phase * 2.1) * tremorEnv
        let raw = p.center
            + sin(time * p.f1 + p.phase) * p.a1
            + sin(time * p.f2 + p.phase * 1.3) * p.a2
            + sin(time * p.f3 + p.phase * 0.9) * p.a3
            + tremor + shared
        let ceiling = (index == 3 || index == 4) ? 0.83 : 0.96
        return Float(max(0.04, min(ceiling, raw)))
    }
}

/// Live waveform bars, driven by `@State` updated through a Combine
/// subscription to LiveAudioMeter.shared.$amplitudes, rather than a
/// TimelineView clock. TimelineView's per-tick schedule turned out not to
/// fire reliably in Knotch's notch overlay window (likely a non-key,
/// non-activating accessory window that doesn't get the steady per-frame
/// heartbeat a normal focused window does) — it would only pick up a fresh
/// frame when something else forced the window to redraw for unrelated
/// reasons. A genuine `@Published` change is a normal SwiftUI state update,
/// the same mechanism already driving the album art/song title elsewhere in
/// this same window, so it doesn't depend on that heartbeat at all.
///
/// Real per-frame geometry (not a scaled static path) means the rounded caps
/// are always true semicircles at any height — no squish-compensation math
/// needed, unlike the old CALayer transform approach.
///
/// Toggling live audio tapping (see `Defaults.liveWaveform`) eases `liveMix`
/// toward 0 (fully simulated) or 1 (fully live) a little every tick instead
/// of hard-switching data sources, so the bars crossfade smoothly rather
/// than dropping to idle and snapping to whichever is newly selected. This
/// is a manual per-frame lerp rather than a SwiftUI `withAnimation` because
/// the amplitude/simulated-time ticks driving normal bar motion re-render
/// every ~33ms without an animation transaction, which would otherwise
/// cancel an implicit animation on `liveMix` almost immediately. The
/// simulated wave's clock keeps running even while live is active, so it
/// never restarts from a cold baseline when it fades back in.
struct AudioSpectrumView: View {
    @Binding var isPlaying: Bool
    @State private var amplitudes: [Float] = Array(repeating: 0, count: AudioSpectrum.barCount)
    @State private var simulatedTime: Double = 0
    @Default(.liveWaveform) private var liveWaveformEnabled
    @State private var liveMix: CGFloat = Defaults[.liveWaveform] ? 1 : 0

    // Exponential approach coefficient applied each 1/30s tick — settles
    // (>98%) to the new target in roughly 0.6s.
    private static let liveMixCoeff: CGFloat = 0.2

    var body: some View {
        HStack(alignment: .center, spacing: AudioSpectrum.spacing) {
            ForEach(0..<AudioSpectrum.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: AudioSpectrum.barWidth / 2, style: .continuous)
                    .fill(Color.white)
                    .frame(width: AudioSpectrum.barWidth, height: AudioSpectrum.barHeight(index, isPlaying: isPlaying, amplitudes: amplitudes, liveMix: liveMix, simulatedTime: simulatedTime))
            }
        }
        .frame(width: AudioSpectrum.contentSize.width, height: AudioSpectrum.contentSize.height)
        .modifier(LiveAmplitudesSubscriber(amplitudes: $amplitudes))
        // Timer.publish, not TimelineView — see the note on LiveAmplitudesSubscriber's
        // sibling mechanism above for why: TimelineView's clock doesn't fire
        // reliably in this notch window, but a real Timer-backed Combine
        // publisher (driving @State like the live data does) does.
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            // Bars are clamped to minHeight whenever !isPlaying (see barHeight),
            // so there's nothing to animate while paused — skip all work then,
            // and also once liveMix has already converged, so this doesn't
            // trigger a re-render on every tick for the rest of a listening
            // session, only during the ~0.6s a transition is actually in flight.
            guard isPlaying else { return }
            simulatedTime += 1.0 / 30.0

            let target: CGFloat = liveWaveformEnabled ? 1 : 0
            if abs(target - liveMix) > 0.001 {
                liveMix += (target - liveMix) * Self.liveMixCoeff
            }
        }
    }
}

/// Attaches the LiveAudioMeter subscription only when it exists (macOS 14.2+),
/// otherwise a no-op — keeps the availability check out of AudioSpectrumView's body.
private struct LiveAmplitudesSubscriber: ViewModifier {
    @Binding var amplitudes: [Float]

    func body(content: Content) -> some View {
        if #available(macOS 14.2, *) {
            content.onReceive(LiveAudioMeter.shared.$amplitudes) { newValue in
                amplitudes = newValue
            }
        } else {
            content
        }
    }
}

/// Blurred, dimmed album art masked to the shape of the running waveform bars.
/// Used both in the closed-notch live activity and the open notch's music view —
/// pulled out so the two don't drift out of sync the way their frame sizes did.
struct AlbumArtWaveformMask: View {
    let albumArt: NSImage
    @Binding var isPlaying: Bool

    private static let artSize = CGSize(width: 36, height: 22)

    var body: some View {
        ZStack {
            Image(nsImage: albumArt)
                .resizable()
                .scaledToFill()
                .frame(width: Self.artSize.width, height: Self.artSize.height)
                .blur(radius: 5)
                .saturation(1.1)
                .brightness(0.03)
            Color.white.opacity(0.04)
                .frame(width: Self.artSize.width, height: Self.artSize.height)
        }
        .mask {
            AudioSpectrumView(isPlaying: $isPlaying)
                .frame(width: AudioSpectrum.recommendedFrameSize.width, height: AudioSpectrum.recommendedFrameSize.height)
        }
        .frame(width: AudioSpectrum.recommendedFrameSize.width, height: AudioSpectrum.recommendedFrameSize.height)
        .clipped()
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
