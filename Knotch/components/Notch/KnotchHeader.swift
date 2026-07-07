//
//  KnotchHeader.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct KnotchHeader: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @ObservedObject var timerManager = TimerManager.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if (!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.knotchShelf] {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.showTimer] {
                            Button(action: {
                                if timerManager.timers.isEmpty {
                                    timerManager.isCreatingTimer = true
                                } else {
                                    timerManager.showTimerList.toggle()
                                }
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: timerManager.timers.isEmpty ? 30 : 60, height: 30)
                                    .overlay {
                                        if let timer = timerManager.soonestActiveTimer {
                                            Text(formatted(timer.remaining()))
                                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                .foregroundColor(.orange)
                                                .contentTransition(.numericText())
                                        } else {
                                            Image(systemName: "timer")
                                                .foregroundColor(.white)
                                                .padding()
                                                .imageScale(.medium)
                                        }
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .popover(isPresented: $timerManager.showTimerList, arrowEdge: .bottom) {
                                TimerListView()
                            }
                            .onChange(of: timerManager.showTimerList) { _, presented in
                                vm.isMediaOutputPopoverActive = presented
                            }
                        }
                        if Defaults[.showMirror] {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                            if Defaults[.settingsIconInNotch] {
                                Button(action: {
                                    DispatchQueue.main.async {
                                        SettingsWindowController.shared.showWindow()
                                    }

                                }) {
                                    Capsule()
                                        .fill(.black)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            Image(systemName: "gearshape.fill")
                                                .foregroundColor(.white)
                                                .padding()
                                                .imageScale(.medium)
                                        }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            if Defaults[.showBatteryIndicator] {
                            KnotchBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }

    func formatted(_ seconds: TimeInterval) -> String {
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

#Preview {
    KnotchHeader().environmentObject(KnotchViewModel())
}
