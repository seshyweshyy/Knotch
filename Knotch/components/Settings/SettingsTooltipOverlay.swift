import SwiftUI

/// Retains the last anchor through dismissal. Only the callout transitions;
/// its position never interpolates from the overlay's default layout origin.
struct SettingsTooltipOverlay: View {
    let request: HoverTooltipPreferenceKey.Request?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text: String?
    @State private var point: CGPoint = .zero
    @State private var isPresented = false
    @State private var generation = 0

    private struct Target: Equatable {
        let text: String
        let point: CGPoint
    }

    var body: some View {
        GeometryReader { proxy in
            let target = request.map { Target(text: $0.text, point: proxy[$0.anchor]) }
            ZStack(alignment: .bottom) {
                if isPresented, let text {
                    TooltipCallout(text: text)
                        .fixedSize()
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.05, anchor: .bottom).combined(with: .opacity))
                }
            }
            // Place the arrow tip, rather than the callout's center, above
            // the source. These modifiers sit outside the animated content.
            .frame(width: 0, height: 0, alignment: .bottom)
            .position(x: point.x, y: point.y - 1)
            .task(id: target) {
                generation += 1
                let currentGeneration = generation
                guard let target else {
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.17), completionCriteria: .removed) {
                        isPresented = false
                    } completion: {
                        guard generation == currentGeneration else { return }
                        text = nil
                    }
                    return
                }

                if isPresented, text == target.text {
                    point = target.point
                    return
                }
                if isPresented {
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.17)) {
                        isPresented = false
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch { return }
                guard !Task.isCancelled else { return }

                var placement = Transaction()
                placement.disablesAnimations = true
                withTransaction(placement) {
                    point = target.point
                    text = target.text
                }
                await Task.yield()
                guard !Task.isCancelled, generation == currentGeneration else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.9)) {
                    isPresented = true
                }
            }
            .onDisappear { generation += 1 }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
