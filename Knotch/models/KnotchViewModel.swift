//
//  KnotchViewModel.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Combine
import Defaults
import SwiftUI

class KnotchViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: KnotchAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed

    @Published var dragDetectorTargeting: Bool = false
    @Published var generalDropTargeting: Bool = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = true

    @Published var edgeAutoOpenActive: Bool = false
    @Published var isHoveringCalendar: Bool = false
    @Published var isBatteryPopoverActive: Bool = false
    @Published var isMediaOutputPopoverActive: Bool = false

    @Published var screenUUID: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()

    // Cosmetic "liquid pull" stretch amount, shared so any gesture surface
    // inside the notch (not just the notch body itself) can drive it —
    // e.g. the calendar day scroller's own horizontal drag.
    @Published var liquidPull: CGFloat = .zero
    @Published var liquidPullHorizontal: CGFloat = .zero

    private var liquidVerticalFactor: CGFloat {
        min(liquidPull, liquidPullClamp) / liquidPullClamp
    }

    private var liquidHorizontalFactor: CGFloat {
        min(abs(liquidPullHorizontal), liquidPullClamp) / liquidPullClamp
    }

    var liquidStretchScale: (x: CGFloat, y: CGFloat) {
        // Kept modest — content is still clipped by the notch's own bezel, so
        // too large a stretch runs past those bounds and gets cut off.
        (x: 1 + liquidHorizontalFactor * 0.015, y: 1 + liquidVerticalFactor * 0.05)
    }

    // Edge opposite the horizontal pull direction, so content only grows
    // toward wherever the cursor dragged rather than away from it too.
    var liquidHorizontalAnchorX: CGFloat {
        liquidPullHorizontal >= 0 ? 0 : 1
    }

    var liquidBlurRadius: CGFloat {
        max(liquidVerticalFactor, liquidHorizontalFactor) * 1.5
    }


    let webcamManager = WebcamManager.shared
    @Published var isScreenLocked: Bool = false
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false
    
    @Published var isUnlockAnimating: Bool = false
    
    @Published var openHomeWidth: CGFloat = openNotchHomeSize.width

    var computedHomeSize: CGSize {
        CGSize(width: openHomeWidth, height: openNotchHomeSize.height)
    }
    
    func lockNotch() {
        self.notchSize = CGSize(
            width: closedNotchSize.width + (2 * max(0, effectiveClosedNotchHeight - 12) + 60),
            height: closedNotchSize.height
        )
    }
    
    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screenUUID: String? = nil) {
        animation = animationLibrary.animation

        super.init()
        
        self.screenUUID = screenUUID
        notchSize = getClosedNotchSize(screenUUID: screenUUID)
        closedNotchSize = notchSize

        Publishers.CombineLatest3($dropZoneTargeting, $dragDetectorTargeting, $generalDropTargeting)
            .map { shelf, drag, general in
                shelf || drag || general
            }
            .assign(to: \.anyDropZoneTargeting, on: self)
            .store(in: &cancellables)
        
        setupDetectorObserver()
        setupWidgetWidthObserver()
    }
    
    
    private func setupDetectorObserver() {
        // Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        // Publisher for the current screen UUID (non-nil, distinct)
        let screenPublisher = $screenUUID
            .compactMap { $0 }
            .removeDuplicates()

        // Publisher for fullscreen status dictionary
        let fullscreenStatusPublisher = detector.$fullscreenStatus
            .removeDuplicates()

        // Combine all three: screen UUID, fullscreen status, and enabled setting
        Publishers.CombineLatest3(screenPublisher, fullscreenStatusPublisher, enabledPublisher)
            .map { screenUUID, fullscreenStatus, enabled in
                let isFullscreen = fullscreenStatus[screenUUID] ?? false
                return enabled && isFullscreen
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupWidgetWidthObserver() {
        Publishers.CombineLatest3(
            Defaults.publisher(.showCalendar).map(\.newValue),
            Defaults.publisher(.showMirror).map(\.newValue),
            $isCameraExpanded
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] cal, mirror, camExpanded in
            guard let self else { return }
            let w = computedOpenNotchHomeWidth(
                showMusic: self.coordinator.musicLiveActivityEnabled,
                showCalendar: cal,
                showMirror: mirror,
                cameraExpanded: camExpanded,
                cameraAvailable: self.webcamManager.cameraAvailable
            )
            self.openHomeWidth = w
            if self.notchState == .open && self.coordinator.currentView == .home && !TimerManager.shared.isCreatingTimer {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                    self.notchSize = self.computedHomeSize
                }
            }
        }
        .store(in: &cancellables)

        // Separately observe musicLiveActivityEnabled via NotificationCenter
        // since coordinator is an @ObservedObject and its $published vars aren't directly pipeable here
        coordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                guard self.notchState == .open && self.coordinator.currentView == .home && !TimerManager.shared.isCreatingTimer else { return }
                let w = computedOpenNotchHomeWidth(
                    showMusic: self.coordinator.musicLiveActivityEnabled,
                    showCalendar: Defaults[.showCalendar],
                    showMirror: Defaults[.showMirror],
                    cameraExpanded: self.isCameraExpanded,
                    cameraAvailable: self.webcamManager.cameraAvailable
                )
                self.openHomeWidth = w
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                    self.notchSize = self.computedHomeSize
                }
            }
            .store(in: &cancellables)
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    var chinHeight: CGFloat {
        if !Defaults[.hideTitleBar] {
            return 0
        }

        guard let currentScreen = screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) else {
            return 0
        }

        if notchState == .open { return 0 }

        let menuBarHeight = currentScreen.frame.maxY - currentScreen.visibleFrame.maxY
        let currentHeight = effectiveClosedNotchHeight

        if currentHeight == 0 { return 0 }

        return max(0, menuBarHeight - currentHeight)
    }

    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
                isCameraExpanded = false
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
                isCameraExpanded = true
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRequestingAuthorization = false
            }

        default:
            break
        }
    }
    
    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        let screenFrame = getScreenFrame(screenUUID)
        if let frame = screenFrame {
            
            let baseY = frame.maxY - notchSize.height
            let baseX = frame.midX - notchSize.width / 2
            
            return position.y >= baseY && position.x >= baseX && position.x <= baseX + notchSize.width
        }
        
        return false
    }

    func open() {
        guard !isScreenLocked else { return }
        // openHomeWidth is normally kept current by a reactive observer, but that
        // observer can lag by a beat behind state that just changed (e.g. right as
        // the notch opens) — recomputing it fresh here avoids opening to a stale
        // width and then visibly correcting to the right one a moment later.
        refreshOpenHomeWidth()
        if TimerManager.shared.isCreatingTimer {
            self.notchSize = CGSize(width: WidgetWidth.timerSlider, height: computedHomeSize.height)
        } else {
            self.notchSize = coordinator.currentView == .home ? computedHomeSize : openNotchSize
        }
        self.notchState = .open
        MusicManager.shared.forceUpdate()
    }

    private func refreshOpenHomeWidth() {
        openHomeWidth = computedOpenNotchHomeWidth(
            showMusic: coordinator.musicLiveActivityEnabled,
            showCalendar: Defaults[.showCalendar],
            showMirror: Defaults[.showMirror],
            cameraExpanded: isCameraExpanded,
            cameraAvailable: webcamManager.cameraAvailable
        )
    }

    func close() {
        if SharingStateManager.shared.preventNotchClose {
            return
        }
        self.notchSize = getClosedNotchSize(screenUUID: self.screenUUID)
        self.closedNotchSize = self.notchSize
        self.notchState = .closed
        self.isBatteryPopoverActive = false
        self.isMediaOutputPopoverActive = false
        self.coordinator.sneakPeek.show = false
        self.edgeAutoOpenActive = false

        // Set the current view to shelf if it contains files and the user enables openShelfByDefault
        // Otherwise, if the user has not enabled openLastShelfByDefault, set the view to home
        if !ShelfStateViewModel.shared.isEmpty && Defaults[.openShelfByDefault] && Defaults[.showShelfView] {
            coordinator.currentView = .shelf
        } else if !coordinator.openLastTabByDefault {
            // Ensure we land on an enabled view
            coordinator.currentView = Defaults[.showHomeView] ? .home : .shelf
        }

        // Never leave the remembered tab pointed at a view the user has disabled
        // (e.g. "open last tab" kept it on Home after Home view was turned off).
        if coordinator.currentView == .home && !Defaults[.showHomeView] {
            coordinator.currentView = .shelf
        } else if coordinator.currentView == .shelf && !Defaults[.showShelfView] {
            coordinator.currentView = .home
        }
    }

    func closeHello() {
        Task { @MainActor in
            withAnimation(animationLibrary.animation) {
                coordinator.helloAnimationRunning = false
                close()
            }
        }
    }
}

extension View {
    // Vertical-only stretch/blur, applied per-widget (header, album art, controls
    // row, etc.) anchored to each widget's own top edge. A down-pull stacks
    // widgets vertically with no overlap, so each one independently growing
    // downward from where it already sits still reads as one cohesive group
    // moving together — no shared anchor needed on this axis.
    func liquidStretch(_ vm: KnotchViewModel) -> some View {
        self
            .scaleEffect(x: 1, y: vm.liquidStretchScale.y, anchor: UnitPoint(x: 0.5, y: 0))
            .blur(radius: vm.liquidBlurRadius)
    }

    // Horizontal-only lean, applied ONCE around the whole header+content group
    // (not per-widget) — side-by-side widgets each stretching from their own
    // edge looks disjointed, whereas one shared anchor makes everything lean
    // toward the pull direction together, like the group is being dragged.
    func liquidHorizontalGroup(_ vm: KnotchViewModel) -> some View {
        self.scaleEffect(x: vm.liquidStretchScale.x, y: 1, anchor: UnitPoint(x: vm.liquidHorizontalAnchorX, y: 0.5))
    }
}
