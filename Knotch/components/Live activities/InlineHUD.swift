//
//  InlineHUDs.swift
//  Knotch
//
//  Created by Richard Kunkli on 14/09/2024.
//

import SwiftUI
import Defaults

struct InlineHUD: View {
    @EnvironmentObject var vm: KnotchViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Binding var hoverAnimation: Bool
    @Binding var gestureProgress: CGFloat
    var label: String = ""
    var tintColor: Color = .white
    @Default(.notchAppearanceStyle) var notchAppearanceStyle

    // When glass is active, this middle strip should let the shared notch
    // background (glass + gradient mask) show through instead of covering
    // it with an opaque black rectangle.
    private var glassActive: Bool {
        notchAppearanceStyle == .semiLiquidGlass || notchAppearanceStyle == .fullLiquidGlass
    }

    // Focus only needs room for an icon and a short "On"/"Off" label, unlike
    // the other types which need space for a name + progress bar.
    private var sideWidth: CGFloat {
        let base: CGFloat = type == .focusMode ? 44 : 100
        return base - (hoverAnimation ? 0 : 12) + gestureProgress / 2
    }

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Group {
                    switch (type) {
                        case .volume:
                            if icon.isEmpty {
                                VolumeHUDLottieView(value: value, displaySize: 24)
                                    .frame(width: 24, height: 24, alignment: .leading)
                            } else {
                                Image(systemName: icon)
                                    .contentTransition(.interpolate)
                                    .opacity(value.isZero ? 0.6 : 1)
                                    .scaleEffect(value.isZero ? 0.85 : 1)
                                    .frame(width: 20, height: 15, alignment: .leading)
                            }
                        case .brightness:
                            DisplayHUDLottieView(value: value, displaySize: 32)
                                .frame(width: 24, height: 24)
                        case .backlight:
                            Image(systemName: value > 0.5 ? "light.max" : "light.min")
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .mic:
                            Image(systemName: "mic")
                                .symbolRenderingMode(.hierarchical)
                                .symbolVariant(value > 0 ? .none : .slash)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .focusMode:
                            Image(systemName: icon.isEmpty ? "moon.fill" : icon)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        default:
                            EmptyView()
                    }
                }
                .foregroundStyle(type == .focusMode ? tintColor : .white)
                .symbolVariant(.fill)

                if type != .focusMode {
                    Text(Type2Name(type))
                        .font(.system(size: 12))
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: sideWidth, height: vm.notchSize.height - (hoverAnimation ? 0 : 12), alignment: .leading)
            
            Rectangle()
                .fill(glassActive ? Color.clear : Color.black)
                .frame(width: vm.closedNotchSize.width - 20)
            
            HStack {
                if (type == .mic) {
                    Text(value.isZero ? "muted" : "unmuted")
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                } else if (type == .focusMode) {
                    Text(label.isEmpty ? "Off" : label)
                        .foregroundStyle(tintColor)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                } else {
                        HStack {
                        DraggableProgressBar(value: $value, onChange: { v in
                            if type == .volume {
                                VolumeManager.shared.setAbsolute(Float32(v))
                            } else if type == .brightness {
                                BrightnessManager.shared.setAbsolute(value: Float32(v))
                            }
                        })
                        if Defaults[.showClosedNotchHUDPercentage] {
                            Text("\(Int(value * 100))%")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                                .allowsTightening(true)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(value)))
                                .animation(.smooth(duration: 0.25), value: Int(value * 100))
                        }
                    }
                }
            }
            .padding(.trailing, 4)
            .frame(width: sideWidth, height: vm.closedNotchSize.height - (hoverAnimation ? 0 : 12), alignment: .center)
        }
        .frame(height: vm.closedNotchSize.height + (hoverAnimation ? 8 : 0), alignment: .center)
    }
    
    func Type2Name(_ type: SneakContentType) -> String {
        switch(type) {
            case .volume:
                return "Sound"
            case .brightness:
                return "Display"
            case .backlight:
                return "Backlight"
            case .mic:
                return "Mic"
            default:
                return ""
        }
    }
}

#Preview {
    InlineHUD(type: .constant(.brightness), value: .constant(0.4), icon: .constant(""), hoverAnimation: .constant(false), gestureProgress: .constant(0))
        .padding(.horizontal, 8)
        .background(Color.black)
        .padding()
        .environmentObject(KnotchViewModel())
}
