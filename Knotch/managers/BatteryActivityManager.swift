import Foundation
import IOKit
import IOKit.ps

/// Manages and monitors battery status changes on the device
/// - Note: This class uses the IOKit framework to monitor battery status
class BatteryActivityManager {

    static let shared = BatteryActivityManager()

    // The controller's instantaneous-current math occasionally spikes to
    // implausible figures (e.g. 900+ hours) when the discharge rate
    // momentarily reads near-zero. No Mac battery lasts anywhere close to
    // a day, so anything past this is noise, not a real estimate.
    private static let maxPlausibleMinutes = 24 * 60

    var onBatteryLevelChange: ((Float) -> Void)?
    var onMaxCapacityChange: ((Float) -> Void)?
    var onPowerModeChange: ((Bool) -> Void)?
    var onPowerSourceChange: ((Bool) -> Void)?
    var onChargingChange: ((Bool) -> Void)?
    var onTimeToFullChargeChange: ((Int) -> Void)?
    var onTimeToEmptyChange: ((Int) -> Void)?

    private var batterySource: CFRunLoopSource?
    private var observers: [(BatteryEvent) -> Void] = []
    private var previousBatteryInfo: BatteryInfo?
    private var notificationQueue: [BatteryEvent] = []
    private var isProcessingNotifications = false

    enum BatteryEvent {
        case powerSourceChanged(isPluggedIn: Bool)
        case batteryLevelChanged(level: Float)
        case lowPowerModeChanged(isEnabled: Bool)
        case isChargingChanged(isCharging: Bool)
        case timeToFullChargeChanged(time: Int)
        case timeToEmptyChanged(time: Int)
        case maxCapacityChanged(capacity: Float)
        case error(description: String)
    }

    enum BatteryError: Error {
        case powerSourceUnavailable
        case batteryInfoUnavailable(String)
        case batteryParameterMissing(String)
    }

    private let defaultBatteryInfo = BatteryInfo(
        isPluggedIn: false,
        isCharging: false,
        currentCapacity: 0,
        maxCapacity: 0,
        isInLowPowerMode: false,
        timeToFullCharge: 0,
        timeToEmpty: 0
    )

    private init() {
        startMonitoring()
        setupLowPowerModeObserver()
    }
    
    /// Setup observer for low power mode changes
    private func setupLowPowerModeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    /// Called when low power mode is enabled or disabled
    @objc private func lowPowerModeChanged() {
        notifyBatteryChanges()
    }
    
    /// Starts monitoring battery changes
    private func startMonitoring() {
        guard let powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<BatteryActivityManager>.fromOpaque(context).takeUnretainedValue()
            manager.notifyBatteryChanges()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            return
        }
        batterySource = powerSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
    }

    /// Stops monitoring battery changes
    private func stopMonitoring() {
        if let powerSource = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
            batterySource = nil
        }
    }

    /// Checks for changes in a property and notifies observers
    private func checkAndNotify<T: Equatable>(
        previous: T, 
        current: T, 
        eventGenerator: (T) -> BatteryEvent
    ) {
        if previous != current {
            enqueueNotification(eventGenerator(current))
        }
    }
    
    /// Notifies the observers of battery changes
    /// Checks for changes in battery status and notifies observers
    private func notifyBatteryChanges() {
        let batteryInfo = getBatteryInfo()
        
        // Check for changes
        if let previousInfo = previousBatteryInfo {
            // Usar la función auxiliar para cada propiedad
            checkAndNotify(
                previous: previousInfo.isPluggedIn,
                current: batteryInfo.isPluggedIn,
                eventGenerator: { .powerSourceChanged(isPluggedIn: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.currentCapacity,
                current: batteryInfo.currentCapacity,
                eventGenerator: { .batteryLevelChanged(level: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.isCharging,
                current: batteryInfo.isCharging,
                eventGenerator: { .isChargingChanged(isCharging: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.isInLowPowerMode,
                current: batteryInfo.isInLowPowerMode,
                eventGenerator: { .lowPowerModeChanged(isEnabled: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.timeToFullCharge,
                current: batteryInfo.timeToFullCharge,
                eventGenerator: { .timeToFullChargeChanged(time: $0) }
            )

            checkAndNotify(
                previous: previousInfo.timeToEmpty,
                current: batteryInfo.timeToEmpty,
                eventGenerator: { .timeToEmptyChanged(time: $0) }
            )

            checkAndNotify(
                previous: previousInfo.maxCapacity,
                current: batteryInfo.maxCapacity,
                eventGenerator: { .maxCapacityChanged(capacity: $0) }
            )
        } else {
            // First time notification
            enqueueNotification(.powerSourceChanged(isPluggedIn: batteryInfo.isPluggedIn))
            enqueueNotification(.batteryLevelChanged(level: batteryInfo.currentCapacity))
            enqueueNotification(.isChargingChanged(isCharging: batteryInfo.isCharging))
            enqueueNotification(.lowPowerModeChanged(isEnabled: batteryInfo.isInLowPowerMode))
            enqueueNotification(.timeToFullChargeChanged(time: batteryInfo.timeToFullCharge))
            enqueueNotification(.timeToEmptyChanged(time: batteryInfo.timeToEmpty))
            enqueueNotification(.maxCapacityChanged(capacity: batteryInfo.maxCapacity))
        }

        // Update previous battery info
        previousBatteryInfo = batteryInfo

        // Trigger optional callbacks
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onBatteryLevelChange?(batteryInfo.currentCapacity)
            self.onPowerSourceChange?(batteryInfo.isPluggedIn)
            self.onChargingChange?(batteryInfo.isCharging)
            self.onPowerModeChange?(batteryInfo.isInLowPowerMode)
            self.onTimeToFullChargeChange?(batteryInfo.timeToFullCharge)
            self.onTimeToEmptyChange?(batteryInfo.timeToEmpty)
            self.onMaxCapacityChange?(batteryInfo.maxCapacity)
        }
    }

    /// Enqueues a notification to be processed
    /// - Parameter event: The battery event
    private func enqueueNotification(_ event: BatteryEvent) {
        notificationQueue.append(event)
        processNextNotification()
    }
    
    /// Processes the next notification in the queue
    /// If there are no more notifications, the queue is cleared
    /// and the processing flag is set to false
    private func processNextNotification() {
        guard !isProcessingNotifications, !notificationQueue.isEmpty else { return }
        isProcessingNotifications = true
        
        let event = notificationQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.notifyObservers(event: event)
            self.isProcessingNotifications = false
            
            // Check if there are more items in the queue
            if !self.notificationQueue.isEmpty {
                self.processNextNotification()
            }
        }
    }
    
    /// Initializes the battery information when the manager starts
    /// - Returns: Current battery information
    func initializeBatteryInfo() -> BatteryInfo {
        previousBatteryInfo = getBatteryInfo()
        guard let batteryInfo = previousBatteryInfo else {
            return BatteryInfo(
                isPluggedIn: false,
                isCharging: false,
                currentCapacity: 0,
                maxCapacity: 0,
                isInLowPowerMode: false,
                timeToFullCharge: 0,
                timeToEmpty: 0
            )
        }
        return batteryInfo
    }

    /// Get the current battery information
    /// - Returns: The current battery information
    private func getBatteryInfo() -> BatteryInfo {
        do {
            // Get power source information
            guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                throw BatteryError.powerSourceUnavailable
            }
            
            guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
                !sources.isEmpty else {
                throw BatteryError.batteryInfoUnavailable("No power sources available")
            }
            
            let source = sources.first!
            
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                throw BatteryError.batteryInfoUnavailable("Could not get power source description")
            }
            
            // Extract required battery parameters with error handling
            guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Float else {
                throw BatteryError.batteryParameterMissing("Current capacity")
            }
            
            guard let maxCapacity = description[kIOPSMaxCapacityKey] as? Float else {
                throw BatteryError.batteryParameterMissing("Max capacity")
            }
            
            guard let isCharging = description["Is Charging"] as? Bool else {
                throw BatteryError.batteryParameterMissing("Charging state")
            }
            
            guard let powerSource = description[kIOPSPowerSourceStateKey] as? String else {
                throw BatteryError.batteryParameterMissing("Power source state")
            }
            
            // Create battery info with the extracted parameters
            var batteryInfo = BatteryInfo(
                isPluggedIn: powerSource == kIOPSACPowerValue,
                isCharging: isCharging,
                currentCapacity: currentCapacity,
                maxCapacity: maxCapacity,
                isInLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                timeToFullCharge: 0,
                timeToEmpty: 0
            )

            // Optional parameters. The public IOKit.ps layer (this
            // dictionary, and IOPSGetTimeRemainingEstimate()) reports "Time
            // to Empty"/"Time to Full Charge" as permanently unknown (-1) on
            // this Mac — confirmed the battery controller itself still has a
            // real figure (ioreg -rn AppleSmartBattery showed "TimeRemaining"
            // = 368 while this dictionary's "Time to Empty" read -1 at the
            // same instant) — so both are read straight from the
            // AppleSmartBattery IORegistry service below instead.
            let estimates = Self.readAppleSmartBatteryTimeEstimates()
            batteryInfo.timeToFullCharge = estimates.timeToFullCharge
                ?? (description[kIOPSTimeToFullChargeKey] as? Int) ?? 0
            batteryInfo.timeToEmpty = estimates.timeToEmpty
                ?? (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 && $0 <= Self.maxPlausibleMinutes ? $0 : nil } ?? 0

            return batteryInfo
            
        } catch BatteryError.powerSourceUnavailable {
            print("⚠️ Error: Power source information unavailable")
            return defaultBatteryInfo
        } catch BatteryError.batteryInfoUnavailable(let reason) {
            print("⚠️ Error: Battery information unavailable - \(reason)")
            return defaultBatteryInfo
        } catch BatteryError.batteryParameterMissing(let parameter) {
            print("⚠️ Error: Battery parameter missing - \(parameter)")
            return defaultBatteryInfo
        } catch {
            print("⚠️ Error: Unexpected error getting battery info - \(error.localizedDescription)")
            return defaultBatteryInfo
        }
    }

    /// Reads "TimeRemaining"/"AvgTimeToFull" straight from the
    /// AppleSmartBattery IORegistry service, bypassing the public IOKit.ps
    /// power-source API entirely — that layer (and `pmset -g batt`) reports
    /// these as permanently unknown on some Macs even though the battery
    /// controller itself has a real figure. 65535 is the controller's own
    /// "not applicable" sentinel (e.g. time-to-full while not charging).
    private static func readAppleSmartBatteryTimeEstimates() -> (timeToEmpty: Int?, timeToFullCharge: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: Any] else {
            return (nil, nil)
        }

        func validMinutes(_ key: String) -> Int? {
            guard let value = props[key] as? Int, value > 0, value != 65535, value <= Self.maxPlausibleMinutes else { return nil }
            return value
        }

        let timeToEmpty = validMinutes("TimeRemaining") ?? validMinutes("AvgTimeToEmpty")
        let timeToFullCharge = validMinutes("AvgTimeToFull")
        return (timeToEmpty, timeToFullCharge)
    }

    /// Adds an observer to listen to battery changes
    /// - Parameter observer: The observer closure to be called on battery events
    /// - Returns: The ID of the observer for later removal
    func addObserver(_ observer: @escaping (BatteryEvent) -> Void) -> Int {
        observers.append(observer)
        return observers.count - 1
    }

    /// Removes an observer by its ID
    /// - Parameter id: The ID of the observer to be removed
    func removeObserver(byId id: Int) {
        guard id >= 0 && id < observers.count else { return }
        observers.remove(at: id)
    }
    
    /// Notifies all observers of a battery event
    /// - Parameter event: The battery event to notify
    private func notifyObservers(event: BatteryEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for observer in self.observers {
                observer(event)
            }
        }
    }
    
    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }
    
}

/// Struct to hold battery information
struct BatteryInfo {
    var isPluggedIn: Bool
    var isCharging: Bool
    var currentCapacity: Float
    var maxCapacity: Float
    var isInLowPowerMode: Bool
    var timeToFullCharge: Int
    /// Minutes remaining until empty while discharging. 0 (or absent from
    /// IOKit) when plugged in / charging / not yet estimated.
    var timeToEmpty: Int
}
