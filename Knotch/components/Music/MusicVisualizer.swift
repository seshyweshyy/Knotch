//
//  MusicVisualizer.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Combine
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

    static func barHeight(_ index: Int, isPlaying: Bool, amplitudes: [Float]) -> CGFloat {
        let minHeight = barWidth
        guard isPlaying else { return minHeight }

        var level: Float = 0
        if index < amplitudes.count, index < boosts.count {
            level = powf(max(0, amplitudes[index]), boosts[index])
        }

        let maxExtra = totalHeight - minHeight
        return minHeight + CGFloat(min(1, level)) * maxExtra
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
/// Resting at dots (rather than a random idle animation) falls out of the
/// height formula for free: no signal → level ≈ 0 → height ≈ barWidth, which
/// covers "paused," "no live meter available," and "song just started, tap
/// hasn't caught up yet" all with the same code path.
struct AudioSpectrumView: View {
    @Binding var isPlaying: Bool
    @State private var amplitudes: [Float] = Array(repeating: 0, count: AudioSpectrum.barCount)

    var body: some View {
        HStack(alignment: .center, spacing: AudioSpectrum.spacing) {
            ForEach(0..<AudioSpectrum.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: AudioSpectrum.barWidth / 2, style: .continuous)
                    .fill(Color.white)
                    .frame(width: AudioSpectrum.barWidth, height: AudioSpectrum.barHeight(index, isPlaying: isPlaying, amplitudes: amplitudes))
            }
        }
        .frame(width: AudioSpectrum.contentSize.width, height: AudioSpectrum.contentSize.height)
        .modifier(LiveAmplitudesSubscriber(amplitudes: $amplitudes))
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
