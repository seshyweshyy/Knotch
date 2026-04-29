//
//  OpenNotchHUD.swift
//  Knotch
//
//  Created by Alexander on 2024-11-23.
//

import SwiftUI
import Defaults

struct OpenNotchHUD: View {
    @EnvironmentObject var vm: KnotchViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Default(.showOpenNotchHUDPercentage) var showPercentage
    
    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Group {
                switch type {
                case .volume:
                    if icon.isEmpty {
                        SpeakerWaveIcon(value: value, size: 11)
                            .fixedSize()
                    } else {
                        Image(systemName: icon)
                            .contentTransition(.interpolate)
                    }
                case .brightness:
                    SunRaysIcon(value: value, size: 18)
                case .backlight:
                    Image(systemName: value > 0.5 ? "light.max" : "light.min")
                        .contentTransition(.interpolate)
                case .mic:
                    Image(systemName: "mic")
                        .symbolVariant(value > 0 ? .none : .slash)
                        .contentTransition(.interpolate)
                default:
                    EmptyView()
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .symbolVariant(.fill)
            .frame(minWidth: 20, alignment: .center)
            
            // Slider or Status Text
            if type != .mic {
                DraggableProgressBar(value: $value, onChange: { newVal in
                     updateSystemValue(newVal)
                })
                .frame(width: showPercentage ? 65 : 108) // Fixed width for consistency
            } else {
                Text(value > 0 ? "Unmuted" : "Muted")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            
            // Percentage Text
            if type != .mic && showPercentage {
                Text("\(Int(value * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
                    .monospacedDigit()
                    .frame(width: 35, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
    
    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch value {
        case 0:           return "speaker.slash"
        case 0...0.33:    return "speaker.wave.1"
        case 0.33...0.66: return "speaker.wave.2"
        default:          return "speaker.wave.3"
        }
    }

    func BrightnessSymbol(_ value: CGFloat) -> String {
        value < 0.5 ? "sun.min" : "sun.max"
    }
    
    func updateSystemValue(_ newVal: CGFloat) {
        switch type {
        case .volume:
            VolumeManager.shared.setAbsolute(Float32(newVal))
        case .brightness:
            BrightnessManager.shared.setAbsolute(value: Float32(newVal))
        default:
            break
        }
    }
}

#Preview {
    OpenNotchHUD(type: .constant(.volume), value: .constant(0.5), icon: .constant(""))
        .environmentObject(KnotchViewModel())
        .padding()
        .background(Color.gray)
}
