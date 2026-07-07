//
//  TimerListView.swift
//  Knotch
//


import SwiftUI

struct TimerListView: View {
    @ObservedObject var timerManager = TimerManager.shared
    @State private var renamingID: UUID?
    @State private var draftName: String = ""

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
                        if renamingID == timer.id {
                            TextField("Name", text: $draftName, onCommit: {
                                timerManager.rename(id: timer.id, name: draftName)
                                renamingID = nil
                            })
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(.orange.opacity(0.8))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onExitCommand { renamingID = nil }
                        } else {
                            Text(timer.name)
                                .font(.system(size: 12, weight: .light))
                                .foregroundStyle(.orange.opacity(0.8))
                                .lineLimit(1)
                                .fixedSize()
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    draftName = timer.name
                                    renamingID = timer.id
                                }
                        }
                        Text(formatted(timer.remaining()))
                            .font(.system(size: 24, weight: .light, design: .rounded))
                            .foregroundStyle(.orange)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }

            if !timerManager.timers.isEmpty {
                Divider()
            }

            Button {
                timerManager.showTimerList = false
                timerManager.isCreatingTimer = true
            } label: {
                HStack {
                    Circle()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: 32, height: 32)
                        .overlay { Image(systemName: "plus").foregroundStyle(.orange) }

                    Text("Add Timer")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(minWidth: 260)
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
