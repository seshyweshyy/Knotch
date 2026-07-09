//
//  TimerCompactPill.swift
//  Knotch
//

import Defaults
import SwiftUI

struct TimerCompactPill: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var timerManager = TimerManager.shared
    @Default(.notchAppearanceStyle) var notchAppearanceStyle

    private var activeColor: Color {
        notchAppearanceStyle == .fullLiquidGlass ? .white : .orange
    }

    var body: some View {
        if let timer = timerManager.soonestActiveTimer {
            HStack {
                Button {
                    timer.isPaused ? timerManager.resume(id: timer.id) : timerManager.pause(id: timer.id)
                } label: {
                    let progress = max(0, min(1, timer.remaining() / timer.duration))

                    ZStack {
                        Circle()
                            .stroke(activeColor.opacity(0.25), lineWidth: 2)
                        // Drains as the timer counts down, rather than filling up.
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(activeColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        // Dial tick riding the drained arc's leading edge.
                        Capsule()
                            .fill(activeColor)
                            .frame(width: 2, height: 5)
                            .offset(y: -3)
                            .frame(width: 16, height: 16)
                            .rotationEffect(.degrees(progress * 360))
                    }
                    .animation(.linear(duration: 1), value: timer.remaining())
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(formatted(timer.remaining()))
                    .font(.system(size: 14, weight: .light, design: .rounded))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(activeColor)
            .padding(.horizontal, 4)
            .frame(width: vm.closedNotchSize.width - 20 + timerCompactPillExtraWidth, height: vm.effectiveClosedNotchHeight, alignment: .center)
        }
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        guard hours > 0 else {
            return String(format: "%d:%02d", minutes, secs)
        }
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
}
