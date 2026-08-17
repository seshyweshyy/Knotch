//
//  MarqueeTextView.swift
//  Knotch
//
//  Created by Richard Kunkli on 08/08/2024.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

// A single inline icon glued to a MarqueeText's leading/mid/trailing position —
// either an SF Symbol or a custom template image asset (e.g. the Lossless/
// Dolby Atmos badges, which have no system symbol equivalent).
struct MarqueeIcon: Equatable {
    enum Source: Equatable {
        case system(String)
        case asset(String)
    }
    let source: Source
    let color: Color

    static func system(_ name: String, color: Color) -> MarqueeIcon {
        MarqueeIcon(source: .system(name), color: color)
    }

    static func asset(_ name: String, color: Color) -> MarqueeIcon {
        MarqueeIcon(source: .asset(name), color: color)
    }

    fileprivate var image: Image {
        switch source {
        case .system(let name): Image(systemName: name)
        case .asset(let name): Image(name).renderingMode(.template)
        }
    }
}

struct MarqueeText: View {
    @Binding var text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let textColor: Color
    let backgroundColor: Color
    let minDuration: Double
    let frameWidth: CGFloat
    let dimmedSubstring: String?
    let dimmedColor: Color
    let scrollSpeed: CGFloat
    let leadingIcon: String?
    let leadingIconColor: Color
    // Rendered in order, each separated by a space — e.g. explicit followed
    // by Lossless/Dolby Atmos quality badges.
    let trailingIcons: [MarqueeIcon]
    // Inserted right before dimmedSubstring's match — e.g. for a "Title • Artist"
    // marquee, this lands right after the title, not at the very end of the string.
    // Has no effect without a matching dimmedSubstring, since that match is its anchor.
    let midIcon: String?
    let midIconColor: Color
    // Opt-in, off by default so every existing caller keeps the original
    // always-leading-aligned layout. When true, text that fits within
    // frameWidth renders as a single centered copy instead of the
    // (mostly invisible) scrolling pair.
    let centerWhenFits: Bool
    // Reports back whether the text is actually scrolling this pass, so
    // callers that mask on an edge fade (sized for scrolling/truncated text)
    // can skip that fade when the text fits and is just centered instead.
    var needsScrollingBinding: Binding<Bool>? = nil
    // Freezes at the resting (leading-edge) position and stops scrolling —
    // for callers whose content stays mounted after the surface closes, so
    // it's back at the start rather than mid-scroll next time it's shown.
    var isPaused: Bool = false

    @State private var textSize: CGSize = .zero
    // Wall-clock time the current scroll cycle started, or nil while at rest
    // (text fits, or not measured yet). The scroll offset below is always
    // recomputed fresh from this on every frame — see scrollingPair.
    @State private var scrollStartDate: Date? = nil

    init(_ text: Binding<String>, font: Font = .body, nsFont: NSFont.TextStyle = .body, textColor: Color = .primary, backgroundColor: Color = .clear, minDuration: Double = 3.0, frameWidth: CGFloat = 200, dimmedSubstring: String? = nil, dimmedColor: Color = .secondary, scrollSpeed: CGFloat = 30, leadingIcon: String? = nil, leadingIconColor: Color = .secondary, trailingIcons: [MarqueeIcon] = [], midIcon: String? = nil, midIconColor: Color = .secondary, centerWhenFits: Bool = false, needsScrollingBinding: Binding<Bool>? = nil, isPaused: Bool = false) {
        _text = text
        self.font = font
        self.nsFont = nsFont
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.minDuration = minDuration
        self.frameWidth = frameWidth
        self.dimmedSubstring = dimmedSubstring
        self.dimmedColor = dimmedColor
        self.scrollSpeed = scrollSpeed
        self.leadingIcon = leadingIcon
        self.leadingIconColor = leadingIconColor
        self.trailingIcons = trailingIcons
        self.midIcon = midIcon
        self.midIconColor = midIconColor
        self.centerWhenFits = centerWhenFits
        self.needsScrollingBinding = needsScrollingBinding
        self.isPaused = isPaused
    }

    private var needsScrolling: Bool {
        !isPaused && textSize.width > frameWidth
    }

    // Prepending/appending the icon here (rather than as a sibling view outside
    // the marquee) keeps it glued to the text as a single scrolling unit — it
    // travels with the title instead of sitting fixed in its own spot.
    private func styledText(_ string: String) -> Text {
        var body: Text
        if let dimmedSubstring, let range = string.range(of: dimmedSubstring) {
            var head = Text(string[string.startIndex..<range.lowerBound])
            let dimmed = Text(string[range]).foregroundColor(dimmedColor)
            let tail = Text(string[range.upperBound...])
            if let midIcon {
                // A literal thin space (rather than a regular space with
                // negative kerning) — kerning applied next to an inline SF
                // Symbol glyph is a known spot where measured width and
                // painted width can drift apart by a point or two, and since
                // textSize.width directly drives the scroll loop's offset
                // math below, that drift would show up as a visible seam at
                // the loop point. A fixed-width character has no such
                // ambiguity.
                let icon = Text(Image(systemName: midIcon)).foregroundColor(midIconColor)
                head = head + Text("\u{2009}") + icon + Text(" ")
            }
            body = head + dimmed + tail
        } else {
            body = Text(string)
        }
        guard leadingIcon != nil || !trailingIcons.isEmpty || midIcon != nil else { return body }

        // Inline SF Symbols in Text render a couple points low relative to
        // the surrounding baseline — nudge everything back up so it sits
        // level with the title. Applied once, after all icon insertion, so
        // leading/mid/trailing together don't stack the offset.
        body = body.baselineOffset(2)
        if let leadingIcon {
            let icon = Text(Image(systemName: leadingIcon)).foregroundColor(leadingIconColor).baselineOffset(2)
            body = icon + Text(" ").baselineOffset(2) + body
        }
        for trailingIcon in trailingIcons {
            let icon = Text(trailingIcon.image).foregroundColor(trailingIcon.color).baselineOffset(2)
            body = body + Text(" ").baselineOffset(2) + icon
        }
        return body
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                measurementProbe
                if needsScrolling {
                    scrollingPair
                } else {
                    restingText
                }
            }
            .frame(width: frameWidth, alignment: .leading)
            .offset(x: centeringOffset)
            .clipped()
        }
        .frame(height: textSize.height * 1.3)
        // Forces every layout consequence of a text change — the
        // measurement probe's textSize update, and everything that derives
        // from it (this frame's height, centeringOffset, the scroll loop
        // restarting) — to apply with zero interpolation, regardless of
        // whatever ambient animation a caller has active around this view
        // (e.g. BlurRevealText's own blur/opacity/scale pulse). Without this,
        // that ambient animation can catch the internal resize/reflow too,
        // which showed up as the text's glyphs visibly sliding into their
        // new positions instead of the old text just cleanly disappearing
        // and the new text appearing already laid out correctly.
        .animation(nil, value: text)
        // Starts the next cycle fresh on un-pause, instead of resuming from
        // a stale scrollStartDate that would jump the cycle-position math.
        .onChange(of: isPaused) { _, paused in
            if !paused, needsScrolling {
                scrollStartDate = Date()
            }
        }
    }

    // Slides resting text into a centered position within frameWidth via a
    // plain numeric offset instead of switching the frame's `alignment:` —
    // alignment is a discrete value SwiftUI can't interpolate mid-animation
    // (it jumps instantly), while an offset is a CGFloat and animates smoothly.
    private var centeringOffset: CGFloat {
        guard centerWhenFits, !needsScrolling else { return 0 }
        return max(0, (frameWidth - textSize.width) / 2)
    }

    // Measures the text's true natural width, independent of whichever of
    // the two layouts below is currently visible — a plain ZStack sibling
    // (not e.g. a .background() of the visible content) so .fixedSize()
    // reports its real intrinsic size rather than whatever the visible
    // content happens to be proposing.
    private var measurementProbe: some View {
        styledText(text)
            .font(font)
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .modifier(MeasureSizeModifier())
            .onPreferenceChange(SizePreferenceKey.self) { size in
                let newSize = CGSize(width: size.width, height: NSFont.preferredFont(forTextStyle: nsFont).pointSize)
                guard newSize.width != textSize.width else { return }
                textSize = newSize
                let willScroll = newSize.width > frameWidth
                scrollStartDate = willScroll ? Date() : nil
                needsScrollingBinding?.wrappedValue = willScroll
            }
    }

    // Two copies placed `spacing` apart; a TimelineView recomputes the
    // scroll offset fresh from elapsed wall-clock time on every single
    // frame, rather than storing a discrete SwiftUI Animation (the previous
    // approach: a toggled Bool driving `.animation(_:value:).repeatForever`)
    // that has to be explicitly restarted whenever content changes. That
    // stored-animation approach is what caused a real bug: an
    // asynchronously-resolved explicit-content badge could arrive after the
    // marquee had already started scrolling, widening the measured text and
    // triggering a second, independent restart that visibly collided with
    // the first mid-transition (seen as the text vanishing and reappearing
    // from the right instead of scrolling continuously). Recomputing the
    // offset as a pure function of time has nothing to restart or collide —
    // a changed textSize/scrollStartDate just changes the inputs, and the
    // displayed position is simply correct on the very next frame.
    private var scrollingPair: some View {
        TimelineView(.animation) { timeline in
            let period = textSize.width + 20
            let scrollDuration = scrollSpeed > 0 ? period / scrollSpeed : 0
            // Pause, then scroll exactly one period, then pause again — matches
            // the original stop-and-go cadence (minDuration applied before every
            // loop, not just the first) rather than a single initial pause
            // followed by nonstop scrolling.
            let cycleDuration = minDuration + scrollDuration
            let elapsedTotal = scrollStartDate.map { timeline.date.timeIntervalSince($0) } ?? 0
            let timeInCycle = cycleDuration > 0 ? elapsedTotal.truncatingRemainder(dividingBy: cycleDuration) : 0
            let wrapped = max(0, timeInCycle - minDuration) * scrollSpeed
            HStack(spacing: 20) {
                styledText(text)
                styledText(text)
            }
            .font(font)
            .foregroundColor(textColor)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -wrapped)
            .background(backgroundColor)
        }
    }

    // No .contentTransition here (tried .opacity previously) — this Text is a
    // concatenation of multiple runs (title + icon glued together, see
    // styledText), and content-transitioning a concatenated Text while any
    // animation is active anywhere in the render doesn't crossfade cleanly:
    // it interpolates per glyph-run, which showed up as the text's letters
    // visibly spreading/reflowing mid-transition. Icon appearance/
    // disappearance now just rides whatever fade the caller wraps the whole
    // MarqueeText in (see BlurRevealText) instead of animating on its own.
    private var restingText: some View {
        styledText(text)
            .font(font)
            .foregroundColor(textColor)
            .fixedSize(horizontal: true, vertical: false)
            .background(backgroundColor)
    }

}
