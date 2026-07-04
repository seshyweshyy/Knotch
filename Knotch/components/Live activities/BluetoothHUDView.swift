//
//  BluetoothHUDView.swift
//  Knotch
//

import SwiftUI
import Defaults

/// Three-phase Bluetooth connection HUD, mimicking the iOS Dynamic Island style.
///
/// Phase 1 – Compact  (0.0 – 0.8s):  pill shows device video icon only (left side)
/// Phase 2 – Expanded (0.8 – 3.5s):  pill widens; shows name, "Connected", battery ring
/// Phase 3 – Compact  (3.5 – 4.3s):  collapses back; icon left, battery ring right (no text)
struct BluetoothHUDView: View {
    let icon: String          // SF Symbol or Apple device asset name (e.g. "airpodspro")
    let deviceName: String
    let batteryFraction: CGFloat  // 0.0–1.0, or -1 if unknown
    @Binding var isExpanded: Bool  // true only during .expanded phase
    
    private enum Phase { case compact, expanded, collapsing }
    
    @State private var phase: Phase = .compact
    @State private var phaseTask: Task<Void, Never>? = nil
    @Default(.bluetoothHUDIconStyle) private var iconStyle: BluetoothHUDIconStyle
    @EnvironmentObject var vm: KnotchViewModel
    
    // Expanded width of the notch pill for this HUD
    private let expandedWidth: CGFloat = 280
    private let compactWidth: CGFloat = 120
    
    var body: some View {
        Group {
            if phase == .compact || phase == .collapsing {
                // Inline layout: sits flush within the closed notch bar
                HStack(spacing: 0) {
                    // LEFT: device icon
                    HStack(spacing: 5) {
                        deviceIcon
                            .frame(
                                width: max(0, vm.effectiveClosedNotchHeight - 4),
                                height: max(0, vm.effectiveClosedNotchHeight - 4)
                            )
                    }
                    .frame(width: max(0, vm.effectiveClosedNotchHeight - 4) + 10, alignment: .leading)
                    
                    // CENTER: black gap over the notch pill
                    Rectangle()
                        .fill(.black)
                        .frame(width: vm.closedNotchSize.width - 20)
                    
                    // RIGHT: battery ring
                    HStack(spacing: 4) {
                        if batteryFraction >= 0 {
                            BatteryRingView(fraction: batteryFraction, lineWidth: 2.5, showsPercentLabel: false)
                                .frame(width: 16, height: 16)
                        }
                    }
                    .padding(.trailing, 4)
                    .frame(width: 30, alignment: .trailing)                }
                .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                .transition(.opacity)
            } else {
                // Expanded pill: drops below notch with name + battery ring
                HStack(spacing: 0) {
                    deviceIcon
                        .frame(width: 52, height: 36)
                        .padding(.leading, 10)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connected")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.gray)
                        Text(deviceName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                    
                    Spacer()
                    
                    if batteryFraction >= 0 {
                        BatteryRingView(fraction: batteryFraction, lineWidth: 3.5)
                            .frame(width: 34, height: 34)
                            .padding(.trailing, 10)
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
                .frame(width: expandedWidth, height: 44)
                .padding(.top, vm.effectiveClosedNotchHeight)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: phase)
        .onChange(of: phase) { _, newPhase in
            isExpanded = newPhase == .expanded
        }
        .onAppear {
            startPhaseSequence()
        }
        .onDisappear {
            phaseTask?.cancel()
        }
    }
    
    // MARK: - Device icon (video if available, else SF symbol)
    
    @ViewBuilder
    private var deviceIcon: some View {
        switch iconStyle {
        case .threeDimensional:
            if let url = Bundle.main.url(forResource: movFileName(for: icon), withExtension: "mov") {
                LoopingVideoView(url: url)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: sfSymbolForIcon(icon))
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
        case .symbol:
            Image(systemName: sfSymbolForIcon(icon))
                .font(.system(size: 18))
                .foregroundStyle(.white)
        }
    }
    
    // MARK: - Player setup
    
    // Map iconName → .mov resource name
    private func movFileName(for icon: String) -> String {
        switch icon {
        case "airpodspro":   return "airpodsPro"
        case "airpods":      return "airpods"
        case "airpodsmax":   return "airpodsMax"
        default:             return icon   // beatssolo, beatsstudio, etc.
        }
    }
    
    // Fallback SF symbol when no .mov exists
    private func sfSymbolForIcon(_ icon: String) -> String {
        switch icon {
        case "airpodspro", "airpods", "airpodsmax": return "airpodspro"
        case "headphones":  return "headphones"
        case "hifispeaker.2": return "hifispeaker.2"
        default: return "headphones"
        }
    }
    
    // MARK: - Phase sequencing
    
    private func startPhaseSequence() {
        phaseTask?.cancel()
        phaseTask = Task { @MainActor [self] in
            do {
                try await Task.sleep(for: .seconds(0.8))
                withAnimation { phase = .expanded }
                try await Task.sleep(for: .seconds(2.7))
                withAnimation { phase = .collapsing }
            } catch {
                // Task was cancelled (view dismissed) — do nothing
            }
        }
    }
}

// MARK: - Battery ring

private struct BatteryRingView: View {
    let fraction: CGFloat
    var lineWidth: CGFloat = 3.5  // customisable per call site
    var showsPercentLabel: Bool = true  // set false to show just the ring, no number

    private var displayPercent: Int { fraction < 0 ? -1 : Int(fraction * 100) }

    // Green 60–100%, yellow 30–59%, red 0–29%. Unknown battery (-1) stays green
    // rather than implying a low-battery warning for a device we simply
    // couldn't read a level from.
    private var ringColor: Color {
        guard fraction >= 0 else { return .green }
        switch displayPercent {
        case 60...:   return .green
        case 30..<60: return .yellow
        default:      return .red
        }
    }

    private var trimEnd: CGFloat { fraction < 0 ? 1.0 : max(0.02, fraction) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: trimEnd)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)

            if showsPercentLabel && displayPercent >= 0 {
                Text("\(displayPercent)")
                    .font(.system(size: lineWidth * 3, weight: .semibold, design: .rounded))
                    .foregroundStyle(ringColor)
            }
        }
    }
}
