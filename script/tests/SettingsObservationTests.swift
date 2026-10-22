import Combine
import SwiftUI

// Minimal coordinator fixture; the observer under test is the production file.
enum NotchViews { case home, tray }
@MainActor
final class KnotchViewCoordinator: ObservableObject {
    static let shared = KnotchViewCoordinator()
    var preferredScreenUUID: String?
    @Published var openLastTabByDefault = false
    @Published var musicLiveActivityEnabled = true
    @Published var alwaysShowTabs = true
    @Published var currentView = NotchViews.home
    @Published var hudProgress = 0.0
}

@main
@MainActor
struct SettingsObservationTests {
    static func main() {
        let source = KnotchViewCoordinator.shared
        let observer = SettingsCoordinatorObserver()
        var invalidations = 0
        let subscription = observer.objectWillChange.sink { invalidations += 1 }
        for step in 0..<100 { source.hudProgress = Double(step) / 100 }
        drain()
        precondition(invalidations == 0, "HUD progress invalidated settings")

        source.preferredScreenUUID = "external-display"
        source.alwaysShowTabs = false
        source.openLastTabByDefault = true
        drain()
        precondition(invalidations == 1, "Preference burst did not coalesce")
        precondition(observer.preferredScreenUUID == "external-display" && !observer.alwaysShowTabs && observer.openLastTabByDefault)

        observer.musicLiveActivityEnabled = false
        precondition(!source.musicLiveActivityEnabled, "Toggle did not reach coordinator")
        precondition(invalidations == 2, "Toggle did not notify settings")
        drain()
        precondition(invalidations == 2, "Toggle notified settings twice")

        source.currentView = .tray
        source.currentView = .home
        drain()
        precondition(invalidations == 2, "Transient unrelated state invalidated settings")
        source.preferredScreenUUID = "changed-through-defaults"
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        drain()
        precondition(observer.preferredScreenUUID == "changed-through-defaults" && invalidations == 3,
                     "External defaults notification did not refresh settings")
        withExtendedLifetime(subscription) {}
        print("Passed settings observation checks: HUD isolation, preference coalescing, binding propagation, duplicate suppression, external defaults updates")
    }

    private static func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
}
