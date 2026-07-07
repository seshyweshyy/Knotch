import SwiftUI
import AppKit
import Defaults

struct TimerSliderView: View {
    @ObservedObject var timerManager = TimerManager.shared

    // Tune the ruler's range/granularity here
    private let minMinutes: Double = 0
    private let maxMinutes: Double = 120
    private let stepMinutes: Double = 1

    @State private var selectedMinutes: Double = 15

    var body: some View {
        VStack(spacing: 8) {
            RulerTimerScrubber(value: $selectedMinutes, range: minMinutes...maxMinutes, step: stepMinutes)
                .frame(maxWidth: .infinity)
                .frame(height: 78)

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
                    .font(.system(size: 26, weight: .light, design: .default))
                    .contentTransition(.numericText())
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.orange)
        .overlay(alignment: .topTrailing) {
            Button {
                timerManager.isCreatingTimer = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(6)
                    .background(Circle().fill(Color.orange.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.trailing, 8)
        }
    }

    private func timeString(from seconds: Double) -> String {
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
    @State private var isMoving = false

    var body: some View {
        GeometryReader { geo in
            let selectedIndex = (value - range.lowerBound) / step
            // Strip's leading edge starts at x = 0 within this ZStack (see
            // `alignment: .leading` below) — this offset shifts it so the
            // tick at `selectedIndex` lands under the fixed center caret.
            let stripOffset = geo.size.width / 2 - (CGFloat(selectedIndex) + 0.5) * pointsPerStep

            ZStack(alignment: .leading) {
                RulerStrip(minValue: range.lowerBound, maxValue: range.upperBound, step: step, pointsPerStep: pointsPerStep, currentValue: value, isMoving: isMoving)
                    .offset(x: stripOffset)

                VStack {
                    Spacer()
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                .frame(width: geo.size.width, alignment: .center)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.3),
                        .init(color: .black, location: 0.7),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
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
                        withAnimation(.easeOut(duration: 0.3)) { isMoving = false }
                    }
            )
            .background(
                RulerScrollCapture { deltaX, ended in
                    if ended {
                        scrollBaseValue = nil
                        scrollAccumulated = 0
                        lastHapticIndex = nil
                        withAnimation(.easeOut(duration: 0.3)) { isMoving = false }
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
        isMoving = true

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
    let isMoving: Bool

    // Wheel curvature via a single Y-axis rotation — this is what actually
    // "wraps" the ticks around a cylinder facing the viewer. No extra
    // vertical scale/offset is stacked on top of it: doing so double-
    // compresses the glyphs (the rotation already foreshortens them via its
    // own perspective), which is what made earlier attempts look warped.
    private let maxAngle: Double = 60        // rotation applied at the edge of the curve, in degrees
    private let curveRange: CGFloat = 220    // px from center over which the full curve ramps up
    private let maxEdgeBlur: CGFloat = 3      // blur radius at the far edges, for the soft fade-out

    // As each tick crosses the center pointer it briefly lights up whiter and
    // glows, then fades back over `highlightRange` — the same "passing under
    // the reticle" glow iOS uses on its ruler/date pickers.
    private let highlightRange: CGFloat = 22

    var body: some View {
        let selectedIndex = (currentValue - minValue) / step

        HStack(spacing: 0) {
            ForEach(0...Int((maxValue - minValue) / step), id: \.self) { i in
                let tickValue = minValue + Double(i) * step
                let isMajor = tickValue.truncatingRemainder(dividingBy: 5) == 0

                let distance = (Double(i) - selectedIndex) * Double(pointsPerStep)
                let normalized = min(max(distance / Double(curveRange), -1), 1)
                let angle = normalized * maxAngle

                let highlight = isMoving ? pow(max(0, 1 - abs(distance) / highlightRange), 2) : 0
                let baseColor = tickValue <= currentValue ? Color.orange : Color.orange.opacity(0.35)
                let tickColor = baseColor.mixed(with: .white, amount: highlight * 0.85)

                VStack(spacing: 6) {
                    Group {
                        if isMajor {
                            Text("\(Int(tickValue))")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .lineLimit(1)
                                .fixedSize()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(height: 18)
                    .blur(radius: pow(abs(normalized), 3) * maxEdgeBlur)
                    .rotation3DEffect(
                        .degrees(angle),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .center,
                        perspective: 0.3
                    )

                    // Ticks stay flat/unrotated so they always sit on one
                    // straight baseline — only the numbers get the wheel curve.
                    Rectangle()
                        .frame(width: isMajor ? 2.5 : 1.5, height: 22)
                }
                .frame(width: pointsPerStep)
                .foregroundStyle(tickColor)
                .shadow(color: Color.orange.opacity(highlight * 0.9), radius: 4 * highlight)
                .opacity(1 - abs(normalized) * 0.55)
                .animation(.easeOut(duration: 0.3), value: isMoving)
            }
        }
    }
}

private extension Color {
    /// Linearly interpolates toward `other` in device RGB space, used to
    /// brighten a tick as it passes under the ruler's center pointer.
    func mixed(with other: Color, amount: Double) -> Color {
        let amount = min(max(amount, 0), 1)
        guard amount > 0 else { return self }
        let c1 = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let c2 = NSColor(other).usingColorSpace(.deviceRGB) ?? NSColor(other)
        return Color(
            red: c1.redComponent + (c2.redComponent - c1.redComponent) * amount,
            green: c1.greenComponent + (c2.greenComponent - c1.greenComponent) * amount,
            blue: c1.blueComponent + (c2.blueComponent - c1.blueComponent) * amount,
            opacity: c1.alphaComponent + (c2.alphaComponent - c1.alphaComponent) * amount
        )
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
