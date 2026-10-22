import Combine
import SwiftUI

/// Settings observe preferences, not every HUD progress/animation update.
@MainActor
final class SettingsCoordinatorObserver: ObservableObject {
    private struct Snapshot: Equatable {
        let screen: String?
        let remembersTab: Bool
        let musicActivity: Bool
        let showsTabs: Bool
        let currentView: NotchViews
    }

    private let source = KnotchViewCoordinator.shared
    @Published private var snapshot: Snapshot
    private var observation: AnyCancellable?
    private var refreshPending = false

    init() {
        let source = KnotchViewCoordinator.shared
        snapshot = Snapshot(screen: source.preferredScreenUUID, remembersTab: source.openLastTabByDefault,
                            musicActivity: source.musicLiveActivityEnabled, showsTabs: source.alwaysShowTabs,
                            currentView: source.currentView)
        observation = source.objectWillChange
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
            guard let self, !self.refreshPending else { return }
            self.refreshPending = true
            // ObservableObject announces before mutation. Coalesce a burst and
            // compare the completed state before invalidating a settings page.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    private func refresh() {
        let updated = Snapshot(screen: source.preferredScreenUUID, remembersTab: source.openLastTabByDefault,
                               musicActivity: source.musicLiveActivityEnabled, showsTabs: source.alwaysShowTabs,
                               currentView: source.currentView)
        if snapshot != updated { snapshot = updated }
    }

    var preferredScreenUUID: String? {
        get { source.preferredScreenUUID }
        set { source.preferredScreenUUID = newValue; refresh() }
    }
    var openLastTabByDefault: Bool {
        get { source.openLastTabByDefault }
        set { source.openLastTabByDefault = newValue; refresh() }
    }
    var musicLiveActivityEnabled: Bool {
        get { source.musicLiveActivityEnabled }
        set { source.musicLiveActivityEnabled = newValue; refresh() }
    }
    var alwaysShowTabs: Bool {
        get { source.alwaysShowTabs }
        set { source.alwaysShowTabs = newValue; refresh() }
    }
    var currentView: NotchViews {
        get { source.currentView }
        set { source.currentView = newValue; refresh() }
    }
}
