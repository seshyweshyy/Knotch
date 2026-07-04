import SwiftUI
import Defaults

/// A view that displays the battery status with an icon and charging indicator.
struct BatteryView: View {

    var levelBattery: Float
    var isPluggedIn: Bool
    var isCharging: Bool
    var isInLowPowerMode: Bool
    var batteryWidth: CGFloat = 26
    var isForNotification: Bool

    var icon: String = "battery.0"

    /// Determines the icon to display when charging.
    var iconStatus: String {
        if isCharging {
            return "bolt"
        }
        else if isPluggedIn {
            return "plug"
        }
        else {
            return ""
        }
    }

    /// Determines the color of the battery based on its status.
    var batteryColor: Color {
        if isInLowPowerMode {
            return .yellow
        } else if levelBattery <= 20 && !isCharging && !isPluggedIn {
            return .red
        } else if isCharging || isPluggedIn || levelBattery == 100 {
            return .green
        } else {
            return .white
        }
    }

    private var bodyHeight: CGFloat {
        batteryWidth / 2.1
    }

    private var terminalHeight: CGFloat {
        max(4, bodyHeight * 0.38)
    }

    private var glyphSystemName: String? {
        guard iconStatus != "" && (isForNotification || Defaults[.showPowerStatusIcons]) else { return nil }
        if isCharging { return "bolt.fill" }
        if isPluggedIn { return "powerplug.fill" }
        return nil
    }

    private var showsGlyph: Bool {
        !showsPercentageInIcon && iconStatus != "" && (isForNotification || Defaults[.showPowerStatusIcons])
    }

    private var showsPercentageInIcon: Bool {
        Defaults[.showBatteryPercentageAsIcon]
    }

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.5))

                GeometryReader { geo in
                    Rectangle()
                        .fill(batteryColor.gradient)
                        .frame(width: max(0, (CGFloat(levelBattery) / 100) * geo.size.width))
                }

                if showsPercentageInIcon {
                    HStack(spacing: -bodyHeight * 0.08) {
                        Text("\(Int32(levelBattery))")
                            .font(.system(size: bodyHeight * 0.9, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .foregroundColor(.black)

                        if iconStatus != "" && Int32(levelBattery) < 100 {
                            Image(iconStatus)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundColor(.black)
                                .frame(width: bodyHeight * 0.8, height: bodyHeight * 0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 1)
                } else if showsGlyph {
                    Image(iconStatus)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.white)
                        .frame(width: bodyHeight * 1.2, height: bodyHeight * 1.2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(width: batteryWidth, height: bodyHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(levelBattery == 100 ? batteryColor.gradient : Color.white.opacity(0.5).gradient)
                .frame(width: 2, height: terminalHeight)
        }
        .scaleEffect(0.93)
        .animation(.smooth(duration: 0.18), value: levelBattery)
        .animation(.smooth(duration: 0.18), value: isCharging)
        .animation(.smooth(duration: 0.18), value: isPluggedIn)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// A view that displays detailed battery information and settings.
struct BatteryMenuView: View {
    
    var isPluggedIn: Bool
    var isCharging: Bool
    var levelBattery: Float
    var maxCapacity: Float
    var timeToFullCharge: Int
    var isInLowPowerMode: Bool
    var onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Text("Battery Status")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(levelBattery))%")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Max Capacity: \(Int(maxCapacity))%")
                    .font(.subheadline)
                    .fontWeight(.regular)
                if isInLowPowerMode {
                    Label("Low Power Mode", systemImage: "bolt.circle")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isCharging {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isPluggedIn {
                    Label("Plugged In", systemImage: "powerplug.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if timeToFullCharge > 0 {
                    Label("Time to Full Charge: \(timeToFullCharge) min", systemImage: "clock")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if !isCharging && isPluggedIn && levelBattery >= 80 {
                    Label("Charging on Hold: Desktop Mode", systemImage: "desktopcomputer")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                    
            }
            .padding(.vertical, 8)

            Divider().background(Color.white)

            Button(action: openBatteryPreferences) {
                Label("Battery Settings", systemImage: "gearshape.fill")
                    .fontWeight(.regular)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
        .padding()
        .frame(width: 280)
        .foregroundColor(.white)
    }

    private func openBatteryPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            openURL(url)
            onDismiss()
        }
    }
}

/// A view that displays the battery status and allows interaction to show detailed information.
struct KnotchBatteryView: View {
    
    @State var batteryWidth: CGFloat = 26
    var isCharging: Bool = false
    var isInLowPowerMode: Bool = false
    var isPluggedIn: Bool = false
    var levelBattery: Float = 0
    var maxCapacity: Float = 0
    var timeToFullCharge: Int = 0
    @State var isForNotification: Bool = false
    
    @State private var showPopupMenu: Bool = false
    @State private var isPressed: Bool = false
    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil

    @EnvironmentObject var vm: KnotchViewModel

    var body: some View {
        Button(action: {
            withAnimation {
                showPopupMenu.toggle()
            }
        }) {
            HStack {
                if Defaults[.showBatteryPercentage] && !Defaults[.showBatteryPercentageAsIcon] {
                    Text("\(Int32(levelBattery))%")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .fixedSize()
                }
                BatteryView(
                    levelBattery: levelBattery,
                    isPluggedIn: isPluggedIn,
                    isCharging: isCharging,
                    isInLowPowerMode: isInLowPowerMode,
                    batteryWidth: batteryWidth,
                    isForNotification: isForNotification
                )
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .popover(
            isPresented: $showPopupMenu,
            arrowEdge: .bottom) {
            BatteryMenuView(
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                levelBattery: levelBattery,
                maxCapacity: maxCapacity,
                timeToFullCharge: timeToFullCharge,
                isInLowPowerMode: isInLowPowerMode,
                onDismiss: { 
                    showPopupMenu = false
                }
            )
            .onHover { hovering in
                isHoveringPopover = hovering
                if hovering {
                    hideTask?.cancel()
                    hideTask = nil
                } else {
                    scheduleHideIfNeeded()
                }
            }
        }
        .onChange(of: showPopupMenu) {
            vm.isBatteryPopoverActive = showPopupMenu
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func scheduleHideIfNeeded() {
        if isHoveringButton || isHoveringPopover { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { showPopupMenu = false } }
        }
    }
}

#Preview {
    KnotchBatteryView(
        batteryWidth: 30,
        isCharging: false,
        isInLowPowerMode: false,
        isPluggedIn: true,
        levelBattery: 80,
        maxCapacity: 100,
        timeToFullCharge: 10,
        isForNotification: false
    ).frame(width: 200, height: 200)
}
