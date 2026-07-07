//
//  TimerListView.swift
//  Knotch
//


import SwiftUI

struct TimerListView: View {
    @ObservedObject var timerManager = TimerManager.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(timerManager.timers) { timer in
                HStack {
                    Button {
                        timer.isPaused ? timerManager.resume(id: timer.id) : timerManager.pause(id: timer.id)
                    } label: {
                        Circle().fill(Color.orange).frame(width: 32, height: 32)
                            .overlay { Image(systemName: timer.isPaused ? "play.fill" : "pause.fill").foregroundStyle(.black) }
                    }
                    .buttonStyle(.plain)

                    Button {
                        timerManager.cancel(id: timer.id)
                    } label: {
                        Circle().fill(Color.gray.opacity(0.3)).frame(width: 32, height: 32)
                            .overlay { Image(systemName: "xmark").foregroundStyle(.white) }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 0) {
                        Text(timer.name).font(.system(size: 12)).foregroundStyle(.orange.opacity(0.8))
                        Text(formatted(timer.remaining()))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .padding(16)
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
