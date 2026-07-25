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
    // Opt-in, off by default so every existing caller keeps the original
    // always-leading-aligned layout. When true, text that fits within
    // frameWidth renders as a single centered copy instead of the
    // (mostly invisible) scrolling pair.
    let centerWhenFits: Bool
    // Reports back whether the text is actually scrolling this pass, so
    // callers that mask on an edge fade (sized for scrolling/truncated text)
    // can skip that fade when the text fits and is just centered instead.
    var needsScrollingBinding: Binding<Bool>? = nil

    @State private var animate = false
    @State private var textSize: CGSize = .zero
    @State private var offset: CGFloat = 0

    init(_ text: Binding<String>, font: Font = .body, nsFont: NSFont.TextStyle = .body, textColor: Color = .primary, backgroundColor: Color = .clear, minDuration: Double = 3.0, frameWidth: CGFloat = 200, dimmedSubstring: String? = nil, dimmedColor: Color = .secondary, scrollSpeed: CGFloat = 30, leadingIcon: String? = nil, leadingIconColor: Color = .secondary, centerWhenFits: Bool = false, needsScrollingBinding: Binding<Bool>? = nil) {
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
        self.centerWhenFits = centerWhenFits
        self.needsScrollingBinding = needsScrollingBinding
    }

    private var needsScrolling: Bool {
        textSize.width > frameWidth
    }

    // Prepending the icon here (rather than as a sibling view outside the
    // marquee) keeps it glued to the text as a single scrolling unit — it
    // travels with the title instead of sitting fixed in its own spot.
    private func styledText(_ string: String) -> Text {
        let body: Text
        if let dimmedSubstring, let range = string.range(of: dimmedSubstring) {
            body = Text(string[string.startIndex..<range.lowerBound])
                + Text(string[range]).foregroundColor(dimmedColor)
                + Text(string[range.upperBound...])
        } else {
            body = Text(string)
        }
        guard let leadingIcon else {
            return body
        }
        // Inline SF Symbols in Text render a couple points low relative to
        // the surrounding baseline — nudge it back up to sit level with the title.
        // The text side gets a small nudge of its own so the two line up —
        // scoped to this leadingIcon path only, so plain (no-icon) marquees
        // elsewhere are unaffected.
        let icon = Text(Image(systemName: leadingIcon)).foregroundColor(leadingIconColor).baselineOffset(2)
        return icon + Text(" ").baselineOffset(2) + body.baselineOffset(2)
    }

    var body: some View {
        if centerWhenFits {
            centeringBody
        } else {
            defaultBody
        }
    }

    private var defaultBody: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 20) {
                    styledText(text)
                    styledText(text)
                        .opacity(needsScrolling ? 1 : 0)
                }
                .id(text)
                .font(font)
                .foregroundColor(textColor)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: self.animate ? offset : 0)
                .animation(
                    self.animate ?
                        .linear(duration: Double(textSize.width / scrollSpeed))
                        .delay(minDuration)
                        .repeatForever(autoreverses: false) : .none,
                    value: self.animate
                )
                .background(backgroundColor)
                .modifier(MeasureSizeModifier())
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    self.textSize = CGSize(width: size.width / 2, height: NSFont.preferredFont(forTextStyle: nsFont).pointSize)
                    self.animate = false
                    self.offset = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01){
                        if needsScrolling {
                            self.animate = true
                            self.offset = -(textSize.width + 10)

                        }
                    }
                }
            }
            .frame(width: frameWidth, alignment: .leading)
            .clipped()
        }
        .frame(height: textSize.height * 1.3)

    }

    // Used only when centerWhenFits is on (currently just the closed-notch
    // music sneak peek row) — everywhere else keeps defaultBody untouched.
    private var centeringBody: some View {
        GeometryReader { geometry in
            ZStack(alignment: needsScrolling ? .leading : .center) {
                // Hidden reference copy, measured on its own so the width it
                // reports is the text's true natural width — decoupled from
                // whichever of the two layouts below is currently visible.
                styledText(text)
                    .font(font)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .id(text)
                    .modifier(MeasureSizeModifier())
                    .onPreferenceChange(SizePreferenceKey.self) { size in
                        self.textSize = CGSize(width: size.width, height: NSFont.preferredFont(forTextStyle: nsFont).pointSize)
                        self.animate = false
                        self.offset = 0
                        needsScrollingBinding?.wrappedValue = needsScrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01){
                            if needsScrolling {
                                self.animate = true
                                // +20 matches the HStack spacing below, so the loop point lines up seamlessly.
                                self.offset = -(textSize.width + 20)
                            }
                        }
                    }

                // Text that fits doesn't need a second scrolling copy — showing
                // just one lets the ZStack center it instead of centering the
                // wider (mostly invisible) scrolling pair.
                if needsScrolling {
                    HStack(spacing: 20) {
                        styledText(text)
                        styledText(text)
                    }
                    .id(text)
                    .font(font)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: self.animate ? offset : 0)
                    .animation(
                        self.animate ?
                            .linear(duration: Double((textSize.width + 10) / scrollSpeed))
                            .delay(minDuration)
                            .repeatForever(autoreverses: false) : .none,
                        value: self.animate
                    )
                    .background(backgroundColor)
                } else {
                    styledText(text)
                        .id(text)
                        .font(font)
                        .foregroundColor(textColor)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(backgroundColor)
                }
            }
            .frame(width: frameWidth, alignment: needsScrolling ? .leading : .center)
            .clipped()
        }
        .frame(height: textSize.height * 1.3)

    }
}
