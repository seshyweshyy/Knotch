//
//  TimerExpandedCard.swift
//  Knotch
//

import Defaults
import SwiftUI

extension TimeInterval {
    /// `m:ss`, or `h:mm:ss` once it reaches an hour — the timer live
    /// activity's countdown format, shared by the compact pill and the
    /// expanded card.
    var timerClockString: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        guard hours > 0 else {
            return String(format: "%d:%02d", minutes, secs)
        }
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
}

/// The timer's expanded closed-state card — the iOS Dynamic Island's
/// expanded timer presentation: round pause + dismiss buttons on the
/// leading side, the timer's name and a large countdown on the trailing
/// side. Sized like the expanded Bluetooth HUD card (280pt wide, 44pt of
/// content below the top inset), but it has no lifecycle of its own —
/// ContentView decides when it is shown and when it collapses.
struct TimerExpandedCard: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var timerManager = TimerManager.shared
    @Default(.notchAppearanceStyle) var notchAppearanceStyle

    /// Collapses the card (after a button already did its own work).
    let onDismiss: () -> Void

    static let width: CGFloat = 280
    static let contentHeight: CGFloat = 44
    private let buttonSize: CGFloat = 36

    private var accent: Color {
        notchAppearanceStyle == .fullLiquidGlass ? .white : .orange
    }

    // With no real notch to drop below in island appearance, the top inset
    // only needs to clear the pill's own rounded top corner — same
    // reasoning as BluetoothHUDView's expanded card.
    private var isIslandAppearance: Bool {
        usesDynamicIslandAppearance(screenUUID: vm.screenUUID)
    }

    var body: some View {
        // A finished timer's alert outranks the running countdown.
        Group {
            if let finished = timerManager.finishedTimers.first {
                finishedContent(finished)
            } else if let timer = timerManager.soonestActiveTimer {
                runningContent(timer)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Self.width, height: Self.contentHeight)
        .padding(.top, isIslandAppearance ? 10 : vm.effectiveClosedNotchHeight)
        .padding(.bottom, 10)
    }

    private func runningContent(_ timer: KnotchTimer) -> some View {
        // The tick reaches this view through TimerManager's plain
        // objectWillChange.send(), which carries no animation — a numeric
        // text transition only rolls its digits inside an animated
        // transaction, so it only played when something unrelated happened to
        // animate at the same moment. Keying an explicit animation to the
        // whole-second value makes every change roll.
        let seconds = Int(timer.remaining())
        return HStack(spacing: 0) {
            controls(for: timer)

            Spacer(minLength: 10)

            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(timer.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(timer.remaining().timerClockString)
                    .font(.system(size: 34, weight: .light))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                    .contentTransition(.numericText(value: Double(seconds)))
                    .animation(.smooth(duration: 0.4), value: seconds)
            }
            .foregroundStyle(accent)
        }
    }

    // The iOS "timer done" alert: the timer's name large on the leading
    // side, restart + dismiss on the trailing side.
    private func finishedContent(_ timer: KnotchTimer) -> some View {
        HStack(spacing: 0) {
            Text(timer.name)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                CardButton(
                    symbol: "arrow.clockwise",
                    glyph: accent,
                    fill: accent.opacity(0.3),
                    size: buttonSize
                ) {
                    timerManager.restartFinished(id: timer.id)
                    dismissIfNoMoreFinished()
                }

                CardButton(
                    symbol: "xmark",
                    glyph: .white,
                    fill: .white.opacity(0.2),
                    size: buttonSize
                ) {
                    if timerManager.finishedTimers.count > 1 {
                        timerManager.dismissFinished(id: timer.id)
                    } else {
                        collapseThen { timerManager.dismissFinished(id: timer.id) }
                    }
                }
            }
        }
    }

    // Another timer may have finished meanwhile — its alert takes over the
    // card instead of collapsing it.
    private func dismissIfNoMoreFinished() {
        if timerManager.finishedTimers.isEmpty { onDismiss() }
    }

    // Collapses the card first, then runs `action` once the close spring has
    // settled — removing the timer straight away would empty the card's
    // content while it's still shrinking away.
    private func collapseThen(_ action: @escaping () -> Void) {
        onDismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }

    @ViewBuilder
    private func controls(for timer: KnotchTimer) -> some View {
        HStack(spacing: 6) {
            switch timer.source {
            case .knotch:
                CardButton(
                    symbol: timer.isPaused ? "play.fill" : "pause.fill",
                    glyph: accent,
                    fill: accent.opacity(0.3),
                    size: buttonSize
                ) {
                    timer.isPaused
                        ? timerManager.resume(id: timer.id)
                        : timerManager.pause(id: timer.id)
                }

                CardButton(
                    symbol: "xmark",
                    glyph: .white,
                    fill: .white.opacity(0.2),
                    size: buttonSize
                ) {
                    collapseThen { timerManager.cancel(id: timer.id) }
                }

            case .systemClock:
                // Mirrored Clock timers are read-only here — the only thing
                // Knotch can do is bring Clock forward, where the real timer
                // can be paused or cancelled.
                CardButton(
                    symbol: "arrow.up.forward.app.fill",
                    glyph: accent,
                    fill: accent.opacity(0.3),
                    size: buttonSize
                ) {
                    timerManager.revealInSystemClock()
                }
            }
        }
    }
}

private struct CardButton: View {
    let symbol: String
    let glyph: Color
    let fill: Color
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(glyph)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(CardButtonStyle())
    }
}

private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
