import SwiftUI
import AppKit
import Defaults

struct TimerSliderView: View {
    @ObservedObject var timerManager = TimerManager.shared

    // 👉 Tune the ruler's range/granularity here.
    private let minMinutes: Double = 0
    private let maxMinutes: Double = 30
    private let stepMinutes: Double = 1

    @State private var selectedMinutes: Double = 15

    var body: some View {
        VStack(spacing: 10) {
            RulerTimerScrubber(value: $selectedMinutes, range: minMinutes...maxMinutes, step: stepMinutes)
                .frame(maxWidth: .infinity)
                .frame(height: 90)

            HStack {
                Button {
                    timerManager.start(name: "Timer", duration: selectedMinutes * 60)
                    timerManager.isCreatingTimer = false
                } label: {
                    Text("Start Timer")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .disabled(selectedMinutes <= 0)
                .fixedSize()

                Spacer(minLength: 8)

                Text(timeString(from: selectedMinutes * 60))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.orange)
    }

    private func timeString(from seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
// MARK: - Ruler-style scrubber

/// A horizontally-scrolling ruler under a fixed center pointer, matching the
/// Clock app's timer picker. Supports click-drag and trackpad two-finger
/// horizontal swipe (via a local scrollWheel monitor, since SwiftUI has no
/// direct trackpad-swipe gesture).
private struct RulerTimerScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    private let pointsPerStep: CGFloat = 10

    @State private var dragStartValue: Double?
    @State private var scrollBaseValue: Double?
    @State private var scrollAccumulated: CGFloat = 0
    @State private var lastHapticIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let selectedIndex = (value - range.lowerBound) / step
            // Strip's leading edge starts at x = 0 within this ZStack (see
            // `alignment: .leading` below) — this offset shifts it so the
            // tick at `selectedIndex` lands under the fixed center caret.
            let stripOffset = geo.size.width / 2 - (CGFloat(selectedIndex) + 0.5) * pointsPerStep

            ZStack(alignment: .leading) {
                RulerStrip(minValue: range.lowerBound, maxValue: range.upperBound, step: step, pointsPerStep: pointsPerStep, currentValue: value)
                    .offset(x: stripOffset)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.18),
                                .init(color: .black, location: 0.82),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )

                VStack {
                    Spacer()
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                .frame(width: geo.size.width, alignment: .center)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStartValue == nil { dragStartValue = value }
                        applyTranslation(drag.translation.width, base: dragStartValue!)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        lastHapticIndex = nil
                    }
            )
            .background(
                RulerScrollCapture { deltaX, ended in
                    if ended {
                        scrollBaseValue = nil
                        scrollAccumulated = 0
                        lastHapticIndex = nil
                        return
                    }
                    if scrollBaseValue == nil { scrollBaseValue = value }
                    scrollAccumulated += deltaX
                    applyTranslation(scrollAccumulated, base: scrollBaseValue!)
                }
            )
        }
    }

    /// Dragging/swiping right reveals lower values (like pulling a physical
    /// ruler to the right under a fixed pointer), matching the Clock app feel.
    private func applyTranslation(_ translation: CGFloat, base: Double) {
        let deltaValue = -Double(translation) / Double(pointsPerStep) * step
        let raw = base + deltaValue
        let stepped = (raw / step).rounded() * step
        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        value = clamped

        let index = Int((clamped - range.lowerBound) / step)
        if Defaults[.enableHaptics], lastHapticIndex != index {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            lastHapticIndex = index
        }
    }
}

private struct RulerStrip: View {
    let minValue: Double
    let maxValue: Double
    let step: Double
    let pointsPerStep: CGFloat
    let currentValue: Double

    // Tune the dial curvature here
    private let maxAngle: Double = 65        // rotation applied at the edge of the curve, in degrees
    private let curveRange: CGFloat = 220    // px from center over which the full curve ramps up

    var body: some View {
        let selectedIndex = (currentValue - minValue) / step

        HStack(spacing: 0) {
            ForEach(0...Int((maxValue - minValue) / step), id: \.self) { i in
                let tickValue = minValue + Double(i) * step
                let isMajor = tickValue.truncatingRemainder(dividingBy: 5) == 0

                // Because the strip is offset so the selected tick always sits at
                // screen-center, each tick's on-screen distance from center is just
                // its index distance from the selected tick, in points.
                let distance = (Double(i) - selectedIndex) * Double(pointsPerStep)
                let normalized = min(max(distance / Double(curveRange), -1), 1)
                let angle = normalized * maxAngle

                VStack(spacing: 6) {
                    if isMajor {
                        Text("\(Int(tickValue))")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Color.clear.frame(height: 18)
                    }
                    Rectangle()
                        .frame(width: 2, height: isMajor ? 26 : 16)
                }
                .frame(width: pointsPerStep)
                .foregroundStyle(tickValue <= currentValue ? Color.orange : Color.orange.opacity(0.35))
                .scaleEffect(y: cos(angle * .pi / 180), anchor: .center)
                .rotation3DEffect(
                    .degrees(angle),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    perspective: 0.35
                )
                .opacity(1 - abs(normalized) * 0.55)
            }
        }
    }
}

/// Captures trackpad two-finger horizontal swipes (scrollWheel events),
/// mirroring the monitor pattern used in extensions/PanGesture.swift.
private struct RulerScrollCapture: NSViewRepresentable {
    /// (deltaX, isEnded)
    let onScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }
    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    final class Coordinator: NSObject {
        private let onScroll: (CGFloat, Bool) -> Void
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat, Bool) -> Void) {
            self.onScroll = onScroll
        }

        func install(on view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak view] event in
                guard event.window === view?.window else { return event }

                if event.phase == .ended || event.momentumPhase == .ended {
                    self.onScroll(0, true)
                    return event
                }

                guard abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) else { return event }
                self.onScroll(event.scrollingDeltaX, false)
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
