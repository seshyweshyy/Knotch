//
//  BlurRevealModifier.swift
//  Knotch
//

import SwiftUI

// Crossfades to a new value with a blur+scale+fade pulse — an outro on the
// value that's finishing, then an intro on the one replacing it. Used for
// song title/artist labels on a track change, and for the sneak peek's
// title/artist (which mounts fresh on every peek — its `if`-gated container
// inserts a brand new view each time, so this pulses on .onAppear too;
// .onChange alone would never fire there, since the text is already its
// final value by the time that view is first rendered).
//
// This renders its own locally-buffered `displayedValue` rather than wrapping
// pre-built content that's already bound live to the caller's state — that's
// deliberate. A modifier that just blurs whatever content is handed to it
// can't actually hide a value swap: by the time SwiftUI delivers the change
// (state updates before the next re-render), the wrapped content already
// reflects the new value, so during the outro's blur-up ramp the new value
// sits there readable for a beat before blur catches up to it. Buffering the
// displayed value here means the outro genuinely shows the OLD value
// dissolving, and the swap to the new one only happens once it's already
// fully hidden (blur/opacity at their outro peak) — so the new value is never
// visible before its own transition has started.
// No default values on these properties — this always goes through the
// custom init below, which supplies its own defaults. Two separate sets of
// "defaults" here previously (property declarations after this comment was
// added vs. the init's own parameter defaults) is exactly what let a fix to
// this file silently not apply: every call site relies on the init's
// defaults, so editing the property declarations alone did nothing.
struct BlurRevealText<Value: Hashable, Content: View>: View {
    let value: Value
    var blurRadius: CGFloat
    // Safe to use now — .id(displayedValue) below forces a hard identity
    // change on every swap, so scale applies uniformly to the fresh,
    // already-replaced content as one flattened layer instead of
    // interacting with Text's own glyph-matching diff (which, not scale's
    // geometry, is what actually caused the earlier letters-sliding bug).
    var startScale: CGFloat
    var anchor: UnitPoint
    var outDuration: Double
    var inDuration: Double
    @ViewBuilder let content: (Value) -> Content

    @State private var displayedValue: Value
    @State private var blur: CGFloat = 0
    @State private var revealOpacity: Double = 1
    @State private var revealScale: CGFloat = 1
    // Bumped on every pulse so a scheduled swap-and-reveal callback from an
    // earlier, superseded pulse (e.g. a skip that landed less than
    // outDuration before the next one) can recognize it's stale and bail
    // instead of swapping in its own now-outdated value.
    @State private var generation: Int = 0

    init(
        _ value: Value,
        blurRadius: CGFloat = 12,
        startScale: CGFloat = 0.85,
        anchor: UnitPoint = .leading,
        outDuration: Double = 0.1,
        inDuration: Double = 0.22,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.value = value
        self.blurRadius = blurRadius
        self.startScale = startScale
        self.anchor = anchor
        self.outDuration = outDuration
        self.inDuration = inDuration
        self.content = content
        _displayedValue = State(initialValue: value)
    }

    private func pulse(to newValue: Value) {
        generation += 1
        let thisGeneration = generation
        // .easeIn (slow start, fast finish) rather than .easeOut here —
        // .easeOut's slow finish meant opacity/scale lingered just above
        // their hidden values for a stretch before actually reaching them,
        // which read as a dead gap between the two labels rather than a
        // continuous motion. Plunging fast at the very end, right as the
        // swap below lands, connects the outro directly into the intro's
        // own fast start (still .easeOut) instead of pausing at empty first.
        withAnimation(.easeIn(duration: outDuration)) {
            blur = blurRadius
            revealOpacity = 0
            revealScale = startScale
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + outDuration) {
            guard thisGeneration == generation else { return }
            // Forced non-animated, rather than left as a bare assignment —
            // otherwise this swap can inherit whatever *ambient*
            // .animation(value:) happens to be active on an ancestor (e.g.
            // the sneak peek row's own mount/show spring), which sweeps up
            // MarqueeText's internal size remeasurement (triggered by this
            // same value change) into that unrelated animation too. That's
            // what caused the artist text's letters to visibly reflow/jitter
            // mid-transition, and separately made the whole pulse sometimes
            // play at that ambient animation's speed instead of ours —
            // occasionally fast enough to read as an instant snap.
            var noAnimation = Transaction()
            noAnimation.disablesAnimations = true
            withTransaction(noAnimation) {
                displayedValue = newValue
            }
            // Pushed to its own runloop tick rather than called immediately
            // after the disablesAnimations transaction above — Core
            // Animation's "disable actions" is a per-commit flag, not
            // cleanly scoped to just the Swift closure it was set within, so
            // an animated call placed right after it in the same synchronous
            // scope could still land in that same disabled commit and apply
            // instantly. That's exactly what was happening here: frame-by-
            // frame capture showed the outro blurring correctly, then the
            // intro (this block) snapping straight to fully revealed in a
            // single frame instead of animating in over inDuration.
            DispatchQueue.main.async {
                guard thisGeneration == generation else { return }
                withAnimation(.easeOut(duration: inDuration)) {
                    blur = 0
                    revealOpacity = 1
                    revealScale = 1
                }
            }
        }
    }

    var body: some View {
        content(displayedValue)
            // Forces a hard identity change on every swap, rather than
            // letting SwiftUI see "the same Text, new string" and diff
            // between them. That diffing is what caused the actual bug: Text
            // does identity-preserving glyph matching between old and new
            // content — common letters held in place, the rest cross-faded —
            // instead of the old value just being replaced by the new one.
            // .animation(nil, value:) doesn't stop that; it's a text-diffing
            // behavior, not a state-transaction animation. Forcing identity
            // to change means there's no "old Text" left for the new one to
            // be diffed against. Safe to remount here specifically because
            // this swap only ever happens once blur/opacity are at their
            // outro peak (fully hidden) — see pulse() — so whatever a fresh
            // mount looks like for a single frame (e.g. MarqueeText's
            // measured size resetting to zero) is invisible when it happens.
            .id(displayedValue)
            // Guarantees the content's OWN re-layout in response to
            // displayedValue changing — Text's glyph/kerning layout, a
            // MarqueeText's internal size remeasurement, anything — never
            // animates, no matter what ambient animation is active when this
            // fires (the outro/intro withAnimation calls below are for OUR
            // blur/opacity/scale only, not for content's internal layout).
            // Without this, whatever's rendering displayedValue can still
            // pick up that ambient animation for its own relayout, which is
            // what showed up as the text's glyphs visibly sliding into their
            // new positions instead of the new value just appearing already
            // laid out correctly. Applies even to plain Text, not just
            // MarqueeText, since e.g. the artist label in some call sites is
            // just a Text bound to displayedValue with no measurement of its
            // own — this is the one guarantee that covers both.
            .animation(nil, value: displayedValue)
            // Flattens the content (often several concatenated Text runs —
            // title plus an inline icon glyph) into one rasterized layer
            // before blur/scale apply. Without this, those transforms can
            // get resolved per sub-element instead of on the compound view
            // as a single unit, which read as the individual glyphs sliding
            // into place at slightly different rates rather than the whole
            // label moving together.
            .compositingGroup()
            .blur(radius: blur)
            .opacity(revealOpacity)
            .scaleEffect(revealScale, anchor: anchor)
            .onAppear { pulse(to: value) }
            .onChange(of: value) { _, newValue in pulse(to: newValue) }
    }
}
