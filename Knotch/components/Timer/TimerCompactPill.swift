//
//  TimerCompactPill.swift
//  Knotch
//

import SwiftUI

struct TimerCompactPill: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var timerManager = TimerManager.shared

    var body: some View {
        if let timer = timerManager.soonestActiveTimer {
            HStack {
                Button {
                    timer.isPaused ? timerManager.resume(id: timer.id) : timerManager.pause(id: timer.id)
                } label: {
                    Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)

                Spacer()

                Text(formatted(timer.remaining()))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight, alignment: .center)
        }
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
