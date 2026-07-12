//
//  LiquidGlassTimerWidget.swift
//  Knotch
//
//  Lock-screen timer widget, styled to match LiquidGlassMusicWidget's glass
//  card but as a compact pill — shows the earliest upcoming timer (native or
//  mirrored from the Clock app) with the same controls as TimerListView's row.
//

import SwiftUI

struct LiquidGlassTimerWidget: View {
    @ObservedObject var timerManager = TimerManager.shared

    var body: some View {
        if let timer = timerManager.soonestActiveTimer {
            if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    row(for: timer)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 10)
                }
            } else {
                row(for: timer)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.55)))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 10)
            }
        }
    }

    @ViewBuilder
    private func row(for timer: KnotchTimer) -> some View {
        HStack(spacing: 10) {
            if timer.source == .systemClock {
                TimerGlassButton(systemImage: "clock", iconColor: .white, tint: .white.opacity(0.15), size: 34) {
                    timerManager.revealInSystemClock()
                }
            } else {
                TimerGlassButton(
                    systemImage: timer.isPaused ? "play.fill" : "pause.fill",
                    iconColor: .orange,
                    tint: .orange.opacity(0.2),
                    size: 34
                ) {
                    timer.isPaused ? timerManager.resume(id: timer.id) : timerManager.pause(id: timer.id)
                }

                TimerGlassButton(systemImage: "xmark", iconColor: .white, tint: .white.opacity(0.15), size: 34) {
                    timerManager.cancel(id: timer.id)
                }
            }

            Spacer(minLength: 16)

            Text(timer.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange.opacity(0.85))
                .lineLimit(1)

            Text(formatted(timer.remaining()))
                .font(.system(size: 22, weight: .light, design: .rounded))
                .foregroundStyle(.orange)
                .contentTransition(.numericText(value: timer.remaining()))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 18)
        .frame(width: 320)
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
