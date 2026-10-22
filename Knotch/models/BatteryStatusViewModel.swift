import Cocoa
import Defaults
import Foundation
import IOKit.ps
import SwiftUI

/// Which metric the battery mini-widget shows.
enum MiniWidgetBatteryMetric: String, CaseIterable, Identifiable, Defaults.Serializable {
    case percentage = "Percentage"
    case timeRemaining = "Time Remaining"
    var id: String { rawValue }
}

/// A view model that manages and monitors the battery status of the device
@MainActor
final class BatteryStatusViewModel: ObservableObject {

    private var wasCharging: Bool = false
    private var powerSourceChangedCallback: IOPowerSourceCallbackType?
    private var runLoopSource: Unmanaged<CFRunLoopSource>?

    @ObservedObject var coordinator = KnotchViewCoordinator.shared

    @Published private(set) var levelBattery: Float = 0.0
    @Published private(set) var maxCapacity: Float = 0.0
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInLowPowerMode: Bool = false
    @Published private(set) var isInitial: Bool = false
    @Published private(set) var timeToFullCharge: Int = 0
    @Published private(set) var timeToEmpty: Int = 0
    @Published private(set) var statusText: String = ""

    private let managerBattery = BatteryActivityManager.shared
    private var managerBatteryId: Int?

    static let shared = BatteryStatusViewModel()

    #if DEBUG
    enum DebugHUDPreset: String, CaseIterable, Identifiable {
        case lowPowerOn = "Low Power Mode On"
        case lowPowerOff = "Low Power Mode Off"
        case charging = "Charging"
        case pluggedIn = "Plugged In"
        case unplugged = "Unplugged"
        case notCharging = "Not Charging"
        case fullCharge = "Full Charge"
        case lowBattery = "Low Battery (20%)"
        case criticalBattery = "Critical Battery (5%)"
        case lowBatteryLPM = "Low Battery + Low Power Mode"

        var id: Self { self }
    }

    @Published private(set) var isDebugHUDPreviewActive = false
    private var debugHUDPreviewTask: Task<Void, Never>?

    func previewBatteryHUD(_ preset: DebugHUDPreset) {
        debugHUDPreviewTask?.cancel()
        isDebugHUDPreviewActive = true
        updateBatteryInfo(BatteryInfo(
            isPluggedIn: [.charging, .pluggedIn, .notCharging, .fullCharge].contains(preset),
            isCharging: preset == .charging,
            currentCapacity: preset == .fullCharge ? 100 : preset == .criticalBattery ? 5
                : [.lowBattery, .lowBatteryLPM].contains(preset) ? 20 : 64,
            maxCapacity: 100,
            isInLowPowerMode: [.lowPowerOn, .lowBatteryLPM].contains(preset),
            timeToFullCharge: preset == .charging ? 45 : 0,
            timeToEmpty: 180
        ))
        statusText = preset.rawValue
        coordinator.toggleExpandingView(status: true, type: .battery)
        debugHUDPreviewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            self?.stopBatteryHUDPreview()
        }
    }

    func stopBatteryHUDPreview() {
        debugHUDPreviewTask?.cancel()
        debugHUDPreviewTask = nil
        guard isDebugHUDPreviewActive else { return }
        if coordinator.expandingView.type == .battery {
            coordinator.toggleExpandingView(status: false, type: .battery)
        }
        isDebugHUDPreviewActive = false
        setupPowerStatus()
    }
    #endif

    var shouldShowBatteryNotifications: Bool {
        #if DEBUG
        if isDebugHUDPreviewActive { return true }
        #endif
        return Defaults[.showPowerStatusNotifications]
    }

    /// Initializes the view model with a given KnotchViewModel instance
    /// - Parameter vm: The KnotchViewModel instance
    private init() {
        setupPowerStatus()
        setupMonitor()
    }

    /// Sets up the initial power status by fetching battery information
    private func setupPowerStatus() {
        let batteryInfo = managerBattery.initializeBatteryInfo()
        updateBatteryInfo(batteryInfo)
    }

    /// Sets up the monitor to observe battery events
    private func setupMonitor() {
        managerBatteryId = managerBattery.addObserver { [weak self] event in
            guard let self = self else { return }
            self.handleBatteryEvent(event)
        }
    }

    /// Handles battery events and updates the corresponding properties
    /// - Parameter event: The battery event to handle
    private func handleBatteryEvent(_ event: BatteryActivityManager.BatteryEvent) {
        #if DEBUG
        guard !isDebugHUDPreviewActive else { return }
        #endif
        switch event {
        case .powerSourceChanged(let isPluggedIn):
            print("🔌 Power source: \(isPluggedIn ? "Connected" : "Disconnected")")
            withAnimation {
                self.isPluggedIn = isPluggedIn
                self.statusText = isPluggedIn ? "Plugged In" : "Unplugged"
                self.notifyImportanChangeStatus()
            }

        case .batteryLevelChanged(let level):
            print("🔋 Battery level: \(Int(level))%")
            withAnimation {
                self.levelBattery = level
            }

        case .lowPowerModeChanged(let isEnabled):
            print("⚡ Low power mode: \(isEnabled ? "Enabled" : "Disabled")")
            self.notifyImportanChangeStatus()
            withAnimation {
                self.isInLowPowerMode = isEnabled
                self.statusText = "Low Power Mode \(self.isInLowPowerMode ? "On" : "Off")"
            }

        case .isChargingChanged(let isCharging):
            print("🔌 Charging: \(isCharging ? "Yes" : "No")")
            print("maxCapacity: \(self.maxCapacity)")
            print("levelBattery: \(self.levelBattery)")
            self.notifyImportanChangeStatus()
            withAnimation {
                self.isCharging = isCharging
                self.statusText =
                    isCharging
                    ? "Charging"
                    : (self.levelBattery < self.maxCapacity ? "Not Charging" : "Full Charge")
            }

        case .timeToFullChargeChanged(let time):
            print("🕒 Time to full charge: \(time) minutes")
            withAnimation {
                self.timeToFullCharge = time
            }

        case .timeToEmptyChanged(let time):
            withAnimation {
                self.timeToEmpty = time
            }

        case .maxCapacityChanged(let capacity):
            print("🔋 Max capacity: \(capacity)")
            withAnimation {
                self.maxCapacity = capacity
            }

        case .error(let description):
            print("⚠️ Error: \(description)")
        }
    }

    /// Updates the battery information with the given BatteryInfo instance
    /// - Parameter batteryInfo: The BatteryInfo instance containing the battery data
    private func updateBatteryInfo(_ batteryInfo: BatteryInfo) {
        withAnimation {
            self.levelBattery = batteryInfo.currentCapacity
            self.isPluggedIn = batteryInfo.isPluggedIn
            self.isCharging = batteryInfo.isCharging
            self.isInLowPowerMode = batteryInfo.isInLowPowerMode
            self.timeToFullCharge = batteryInfo.timeToFullCharge
            self.timeToEmpty = batteryInfo.timeToEmpty
            self.maxCapacity = batteryInfo.maxCapacity
            self.statusText = batteryInfo.isPluggedIn ? "Plugged In" : "Unplugged"
        }
    }

    /// Notifies important changes in the battery status with an optional delay
    /// - Parameter delay: The delay before notifying the change, default is 0.0
    private func notifyImportanChangeStatus(delay: Double = 0.0) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.coordinator.toggleExpandingView(status: true, type: .battery)
        }
    }

}
