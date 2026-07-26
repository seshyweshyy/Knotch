//
//  KnotchViewModel.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Combine
import Defaults
import SwiftUI
import os

private let dragDiagnosticsLogger = Logger(subsystem: "seshyweshyy.Knotch", category: "DragDropDiagnostics")

class KnotchViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: KnotchAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed

    @Published var dragDetectorTargeting: Bool = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = true

    @Published var edgeAutoOpenActive: Bool = false
    @Published var isHoveringCalendar: Bool = false
    @Published var showingCompactCalendar: Bool = false
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

    // Horizontal-only — vertical pull's deform is pullDownDeformScale below.
    var liquidHorizontalStretchScale: CGFloat {
        // Kept modest — content is clipped by the notch's own bezel.
        1 + liquidHorizontalFactor * 0.015
    }

    // Content elongation for pull-down-to-open, cosmetic only (notchSize is
    // untouched). Standard mode's factor is much smaller than Compact's —
    // its layout has more content near the bottom edge and clips at Compact's amount.
    var pullDownDeformScale: CGFloat {
        let maxStretch: CGFloat = Defaults[.enableCompactUI] ? 0.16 : 0.02
        return 1 + liquidVerticalFactor * maxStretch
    }

    // Edge opposite the horizontal pull direction, so content only grows
    // toward wherever the cursor dragged rather than away from it too.
    var liquidHorizontalAnchorX: CGFloat {
        liquidPullHorizontal >= 0 ? 0 : 1
    }

    var liquidBlurRadius: CGFloat {
        max(liquidVerticalFactor, liquidHorizontalFactor) * 1.5
    }

    // One-shot spring bounce applied to the notch's own outer edge when a HUD
    // value (volume/brightness) hits its 0% or 100% limit — signed so +1 pops
    // the right edge outward (100%) and -1 pops the left edge (0%). Set directly
    // to the peak, then released back to zero through liquidReleaseSpring so it
    // overshoots/wobbles on the way down, same as the liquid pull release.
    @Published var hudEdgeOvershoot: CGFloat = .zero

    var hudOvershootScale: CGFloat {
        1 + abs(hudEdgeOvershoot) * 0.03
    }

    var hudOvershootAnchorX: CGFloat {
        hudEdgeOvershoot >= 0 ? 0 : 1
    }

    // Set at the top of open() — lets setupWidgetWidthObserver's correction
    // sinks tell whether a width correction is landing while the open
    // spring is still settling (see their use below).
    private var lastOpenAt: Date = .distantPast

    // True from open() until MusicManager.forceUpdate()'s async playback-state
    // fetch reports back. A width correction landing while this is true is
    // very likely a direct consequence of that fetch resolving, rather than
    // an unrelated later change (e.g. the user toggling Settings) — see
    // applyCorrectedNotchSize below. forceUpdate()'s fetch time varies with
    // system load (AppleScript queries in particular), so a fixed timer
    // alone under- or over-shoots depending on how fast it happens to
    // resolve — which is why the resulting glitch was intermittent rather
    // than consistent. Tracking the real completion removes that guesswork;
    // openSettleWindow stays as a fallback in case completion never fires.
    private var isSettlingFromOpen: Bool = false

    func triggerHUDLimitBounce(rightEdge: Bool) {
        guard Defaults[.hudOvershootEnabled] else { return }
        hudEdgeOvershoot = rightEdge ? 1 : -1
        withAnimation(hudLimitBounceSpring) {
            hudEdgeOvershoot = .zero
        }
    }


    let webcamManager = WebcamManager.shared
    @Published var isScreenLocked: Bool = false
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false
    
    @Published var isUnlockAnimating: Bool = false
    
    @Published var openHomeWidth: CGFloat = openNotchHomeSize.width

    var computedHomeSize: CGSize {
        if Defaults[.enableCompactUI] {
            return compactOpenNotchSize
        }
        return CGSize(width: openHomeWidth, height: openNotchHomeSize.height)
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

        Publishers.CombineLatest($dropZoneTargeting, $dragDetectorTargeting)
            .map { shelf, drag in
                shelf || drag
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
                let newSize = self.computedHomeSize
                // Skip re-animating when nothing actually changed — this sink
                // fires on every calendar/mirror/camera publish, including ones
                // that don't affect the computed width, and re-triggering the
                // spring with a no-op target can still interrupt/restart an
                // in-flight open animation under a different curve.
                guard newSize != self.notchSize else { return }
                self.applyCorrectedNotchSize(newSize)
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
                let newSize = self.computedHomeSize
                // coordinator.objectWillChange fires on ANY published change
                // on the coordinator (sneakPeek, expandingView, etc.), most of
                // which don't affect the computed width — e.g. the async
                // playback-state fetch kicked off by open()'s forceUpdate()
                // call lands mid-open-transition.
                guard newSize != self.notchSize else { return }
                self.applyCorrectedNotchSize(newSize)
            }
            .store(in: &cancellables)
    }

    // Fallback cap on isSettlingFromOpen in case MusicManager.forceUpdate()'s
    // completion never fires for some reason (e.g. no active controller ever
    // becomes active) — without this, a missed completion would leave
    // isSettlingFromOpen stuck true and corrections would keep snapping
    // instantly instead of animating once the notch is genuinely just
    // sitting open. Comfortably longer than forceUpdate() should ever take.
    private let openSettleWindow: TimeInterval = 1.5

    // Applying a width correction here always used liquidReleaseSpring to
    // match the open transition's curve, but that alone doesn't stop it from
    // *retargeting* an open spring that's still mid-flight. open() kicks off
    // an async MusicManager.forceUpdate() fetch, and if that changes
    // coordinator.sneakPeek/expandingView (which computedOpenNotchHomeWidth
    // reads via musicLiveActivityEnabled/showMusic-adjacent state) once it
    // resolves, this fires while the original open spring may still be in
    // flight. Two overlapping springs aiming at different targets compounds
    // into an extra, irregular wobble on top of the open spring's own
    // (consistent) overshoot — and since forceUpdate()'s resolve time varies
    // with system load, that extra wobble showed up intermittently rather
    // than as a fixed part of the curve. isSettlingFromOpen tracks the real
    // completion instead of guessing a fixed duration, so this reliably
    // applies the correction instantly (no animation) for exactly as long as
    // open() is still catching up, and animates normally for anything after.
    private func applyCorrectedNotchSize(_ newSize: CGSize) {
        if isSettlingFromOpen || Date().timeIntervalSince(lastOpenAt) < openSettleWindow {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.notchSize = newSize
            }
        } else {
            withAnimation(liquidReleaseSpring) {
                self.notchSize = newSize
            }
        }
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
        lastOpenAt = Date()
        // NSGlassEffectView's backdrop capture goes stale the same way it
        // does on space/app switches (see KnotchSkyLightWindow's other use
        // of refreshGlassBackdrop) — just triggered by this panel's own
        // resize instead. Without this nudge, the glass visibly kept
        // resolving its edges for a beat after the open spring had already
        // settled. See KnotchSkyLightWindow.knotchWillOpen for the handler.
        NotificationCenter.default.post(name: .knotchWillOpen, object: nil)
        // liquidPullHorizontal/hudEdgeOvershoot only reset on a gesture's
        // .ended phase or a HUD bounce completing — an interrupted drag or a
        // HUD limit bounce shortly before opening can leave either non-zero.
        // Since they ride the same vm.notchState-keyed liquidReleaseSpring as
        // the rest of this transition, a stale nonzero value visibly
        // overshoots left/right on open instead of just staying at zero.
        // Resetting with animations disabled snaps them to zero with no
        // animation, rather than animating "back" to zero through the spring.
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            liquidPullHorizontal = .zero
            hudEdgeOvershoot = .zero
        }
        // openHomeWidth is normally kept current by a reactive observer, but that
        // observer can lag by a beat behind state that just changed (e.g. right as
        // the notch opens) — recomputing it fresh here avoids opening to a stale
        // width and then visibly correcting to the right one a moment later.
        refreshOpenHomeWidth()
        // Explicit withAnimation, driven from the state change itself,
        // instead of an ambient .animation(_:value:) modifier in ContentView.
        withAnimation(notchOpenSpring) {
            if TimerManager.shared.isCreatingTimer {
                self.notchSize = CGSize(width: WidgetWidth.timerSlider, height: computedHomeSize.height)
            } else {
                // Same size for both home and shelf now (see the matching
                // change in ContentView's onChange(of: coordinator.currentView))
                // — no more width transition between them at all.
                self.notchSize = computedHomeSize
            }
            self.notchState = .open
        }
        // TEMP DIAGNOSTIC — remove once the drop-zone highlight bug is root-caused.
        //dragDiagnosticsLogger.debug("[KnotchViewModel] notchState -> open")
        isSettlingFromOpen = true
        MusicManager.shared.forceUpdate { [weak self] in
            self?.isSettlingFromOpen = false
        }
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
        // MusicLiveActivity's height is keyed to sneakPeek.show with its own bouncy
        // spring, which fights notchCloseSpring if reset mid-close. Settle both
        // flags in their own non-animated update first, before the spring starts.
        var immediateTransaction = Transaction()
        immediateTransaction.disablesAnimations = true
        withTransaction(immediateTransaction) {
            self.coordinator.sneakPeek.show = false
            self.coordinator.expandingView.show = false
        }
        // See KnotchSkyLightWindow.knotchWillClose — refreshes the glass backdrop on close too.
        NotificationCenter.default.post(name: .knotchWillClose, object: nil)
        // Matches open() above — explicit withAnimation, not an ambient modifier.
        withAnimation(notchCloseSpring) {
            self.notchSize = getClosedNotchSize(screenUUID: self.screenUUID)
            self.closedNotchSize = self.notchSize
            self.notchState = .closed
        }
        self.isBatteryPopoverActive = false
        self.isMediaOutputPopoverActive = false
        self.showingCompactCalendar = false
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
    // Pull-down deform/blur, applied per-widget, anchored to each widget's
    // own top edge so a down-pull elongates them together as one group.
    func liquidStretch(_ vm: KnotchViewModel) -> some View {
        self
            .scaleEffect(x: 1, y: vm.pullDownDeformScale, anchor: UnitPoint(x: 0.5, y: 0))
            .blur(radius: vm.liquidBlurRadius)
    }

    // Horizontal-only lean, applied ONCE around the whole header+content group
    // (not per-widget) — side-by-side widgets each stretching from their own
    // edge looks disjointed, whereas one shared anchor makes everything lean
    // toward the pull direction together, like the group is being dragged.
    func liquidHorizontalGroup(_ vm: KnotchViewModel) -> some View {
        self.scaleEffect(x: vm.liquidHorizontalStretchScale, y: 1, anchor: UnitPoint(x: vm.liquidHorizontalAnchorX, y: 0.5))
    }
}
