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

// The pages Compact mode can show/swipe between — mirrors the standard
// home/tray tabs, but as a single fixed-size panel instead of separate tabs.
enum CompactPage: Equatable {
    case music
    case calendar
    case tray
    case converter
}

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
    @Published var compactPage: CompactPage = .music
    @Published var isBatteryPopoverActive: Bool = false
    @Published var isMediaOutputPopoverActive: Bool = false

    // Transient drag overlay for Compact mode — true while a file is being
    // dragged near the notch, regardless of which compact page was showing
    // before it started.
    @Published var isCompactDragOverlayActive: Bool = false
    // Set when the drag overlay itself opened a closed notch, so a drag that
    // exits without dropping can close it back up instead of leaving it open.
    var isCompactDragAutoOpened: Bool = false
    // Set synchronously the instant any compact drop square accepts a drop,
    // before whatever async work it still needs to do (e.g. Converter
    // resolving the dropped file's URL before it has anything to show).
    // Distinguishes "a drop landed and is still being processed" from "still
    // actively dragging", so a stray drag-exit-region event arriving mid-async
    // work doesn't get mistaken for an abandoned drag and close the notch out
    // from under it — see KnotchApp.handleDragExitsNotchRegion.
    var isCompactDragCommitted: Bool = false
    // See setupTrayEmptyGracePeriod — kept true for a brief window after the
    // tray empties out, so availableCompactPages doesn't withdraw .tray
    // before CompactTrayView's own onChange handler gets a chance to leave
    // the page gracefully.
    @Published private(set) var isTrayEmptyGracePeriodActive: Bool = false
    private var trayEmptyGraceTask: Task<Void, Never>?

    // Which compact pages are currently reachable by swipe — music/calendar
    // per their own settings, tray only once the tray actually has items
    // (or is still within its empty grace period, see above).
    var availableCompactPages: [CompactPage] {
        var pages: [CompactPage] = []
        if Defaults[.compactShowMusicView] { pages.append(.music) }
        if Defaults[.compactShowCalendarView] { pages.append(.calendar) }
        if !TrayStateViewModel.shared.isEmpty || isTrayEmptyGracePeriodActive { pages.append(.tray) }
        if FileConverterViewModel.shared.hasItem { pages.append(.converter) }
        return pages.isEmpty ? [.music] : pages
    }

    // The page actually shown right now — falls back to the first available
    // page if the remembered one became unreachable (e.g. the tray emptied
    // out from under it).
    var resolvedCompactPage: CompactPage {
        let pages = availableCompactPages
        return pages.contains(compactPage) ? compactPage : pages[0]
    }

    func cycleCompactPage() {
        let pages = availableCompactPages
        guard pages.count > 1, let index = pages.firstIndex(of: resolvedCompactPage) else { return }
        compactPage = pages[(index + 1) % pages.count]
    }

    // Called from the Converter page's own X button. Clearing
    // FileConverterViewModel.item immediately would empty out
    // CompactFileConverterView's content a beat before the outer page-switch
    // transition even starts, so the "blur away" would animate an already-
    // blank box instead of the file tile/buttons — leaves the page first
    // (with the item still intact, so .liveActivityPop captures real content
    // sliding out) and only clears the item once that's had time to play.
    func dismissCompactConverterPage() {
        let itemIDToClear = FileConverterViewModel.shared.item?.id
        compactPage = availableCompactPages.first(where: { $0 != .converter }) ?? .music
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard FileConverterViewModel.shared.item?.id == itemIDToClear else { return }
            FileConverterViewModel.shared.clear()
        }
    }

    // Called once CompactTrayView notices the tray's item count hit zero,
    // regardless of which action emptied it (the "All" button, an
    // individual item's own remove button, auto-remove-on-drag-out). Unlike
    // dismissCompactConverterPage there's no state left to clear here — the
    // tray is already empty by the time this fires — this just leaves the
    // page so resolvedCompactPage's own fallback takes over.
    func dismissCompactTrayPage() {
        guard compactPage == .tray else { return }
        compactPage = availableCompactPages.first(where: { $0 != .tray }) ?? .music
    }

    // Ends the transient drag overlay — shared by every drop square's own
    // handler and by the "dragged out without dropping" exit path. Passing a
    // page (e.g. .tray/.converter once they actually have something to show)
    // reveals it and leaves the notch open; passing nil (AirDrop, or an
    // abandoned drag) closes the notch back down if the drag itself was what
    // opened it, since there's nothing new left worth showing.
    func finishCompactDragOverlay(revealing page: CompactPage? = nil) {
        // Idempotency guard — both a drop's own async completion and a stray
        // exit event can end up calling this; only the first should touch
        // SharingStateManager's reference count.
        guard isCompactDragOverlayActive || isCompactDragCommitted else { return }

        // Abandoned drag that auto-opened a closed notch — nothing new to
        // show, so close directly instead of hiding the overlay first.
        // Hiding it would immediately reveal whatever compact page was
        // underneath (e.g. music, from before this drag ever started) for
        // the moment before the notch shuts, which read as an unwanted
        // flash — staggering the two animations with a delay (an earlier
        // attempt at this) only made that flash last longer, since the
        // wrong content was still the first thing shown either way.
        // Deliberately leaves isCompactDragOverlayActive/isCompactDragCommitted
        // untouched here — the drop-zone squares stay the visible content
        // all the way through the close animation, and close()'s own
        // completion handler already resets both (with compactPage) once
        // the notch is safely hidden, invisibly, the same way it already
        // resets compactPage today.
        if page == nil, isCompactDragAutoOpened {
            SharingStateManager.shared.endInteraction()
            isCompactDragAutoOpened = false
            close()
            return
        }

        // Matches beginDragOverlay's beginInteraction.
        SharingStateManager.shared.endInteraction()
        isCompactDragOverlayActive = false
        isCompactDragCommitted = false
        if let page {
            compactPage = page
            isCompactDragAutoOpened = false
        }
    }

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
    // untouched). Both modes apply this as a single scale over their whole
    // content group now (see standardContent/compactContent), anchored at the
    // panel's top — so a bottom-row element's actual travel is maxStretch *
    // its own distance from that anchor, not just maxStretch alone. Standard's
    // panel is both taller (190pt vs. Compact's 160pt) and pulls further
    // (70pt clamp vs. Compact's 0.7x-reduced 49pt), so its factor has to stay
    // well below Compact's to land on similar-looking travel for its own
    // bottom row (the button toolbar) instead of overshooting it.
    var pullDownDeformScale: CGFloat {
        let maxStretch: CGFloat = Defaults[.enableCompactUI] ? 0.16 : 0.045
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

    // Which edge is anchored for the current bounce — set once per trigger,
    // not derived live from hudEdgeOvershoot's sign. hudLimitBounceSpring's
    // dampingFraction (0.95) isn't quite critically damped, so the release
    // can wobble a hair past zero to the opposite sign right at the tail end;
    // deriving the anchor from that sign live meant the scaleEffect's anchor
    // could flip sides mid-release, which reads as the *whole* notch jumping
    // sideways rather than just the one edge stretching. Pinning it here for
    // the whole bounce keeps the anchor (and so the fixed edge) constant
    // regardless of that tail-end wobble.
    @Published var hudOvershootAnchorX: CGFloat = 0.5

    var hudOvershootScale: CGFloat {
        1 + abs(hudEdgeOvershoot) * 0.03
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
        // The scale effect this drives wraps the whole notch shape, closed
        // pill or open panel alike — bouncing it while open visibly warps
        // the expanded music player/home view, not just a small HUD pill.
        // A closed-state live activity (music bar, timer pill) still counts
        // as closed, so this only excludes the actual open panel.
        guard Defaults[.hudOvershootEnabled], notchState == .closed else { return }
        // Snapped instantly (not animated) — only hudEdgeOvershoot's own
        // decay back to zero should visibly animate; the anchor itself is a
        // fixed choice for this whole bounce, not something that eases in.
        var noAnim = Transaction()
        noAnim.disablesAnimations = true
        withTransaction(noAnim) {
            hudOvershootAnchorX = rightEdge ? 0 : 1
        }
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
            .map { tray, drag in
                tray || drag
            }
            .assign(to: \.anyDropZoneTargeting, on: self)
            .store(in: &cancellables)

        setupTrayEmptyGracePeriod()
        setupDetectorObserver()
        setupWidgetWidthObserver()
    }

    // The tray can go empty via several different removal paths (the "All"
    // button, an individual item's own remove button, auto-remove-on-drag-out)
    // with no single dismiss action to hook into the way
    // dismissCompactConverterPage has one. Without this, availableCompactPages
    // drops .tray the instant TrayStateViewModel's items empties, and
    // resolvedCompactPage's automatic fallback yanks CompactTrayView out of
    // the tree on that very same render pass — before its own onChange
    // handler (which needs the view to still be mounted) ever gets a chance
    // to leave gracefully with content still visible. Keeping .tray nominally
    // "available" for a brief grace window after it empties gives that
    // handler room to run and explicitly change compactPage first, the same
    // "explicit change happens before the reactive fallback" ordering that
    // already makes the Converter dismiss button correctly.
    private func setupTrayEmptyGracePeriod() {
        TrayStateViewModel.shared.$items
            .map(\.isEmpty)
            .removeDuplicates()
            .sink { [weak self] isEmpty in
                guard let self else { return }
                self.trayEmptyGraceTask?.cancel()
                if isEmpty {
                    self.isTrayEmptyGracePeriodActive = true
                    self.trayEmptyGraceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(400))
                        self?.isTrayEmptyGracePeriodActive = false
                    }
                } else {
                    self.isTrayEmptyGracePeriodActive = false
                }
            }
            .store(in: &cancellables)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.isRequestingAuthorization = false
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
                // Same size for both home and tray now (see the matching
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
        } completion: { [weak self] in
            // Resetting compact mode back to the music view only once the close
            // has finished — doing it inline would cross-fade calendar → music
            // in full view while the notch is still collapsing. Skipped if the
            // notch got reopened in the meantime.
            //
            // The withAnimation completion above fires as soon as
            // notchCloseSpring itself settles, but ContentView's own outer
            // `if vm.notchState == .open` removal transition (NotchHomeView's
            // scale/opacity/blur fade-out) can still be finishing a beat
            // later — resetting compactPage here with disablesAnimations
            // landed as a visible snap-to-music right at its tail end. A
            // short extra buffer lets that transition fully settle first.
            guard let self else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.notchState == .closed else { return }
                var resetTransaction = Transaction()
                resetTransaction.disablesAnimations = true
                withTransaction(resetTransaction) {
                    self.compactPage = .music
                    self.isCompactDragOverlayActive = false
                    self.isCompactDragAutoOpened = false
                    self.isCompactDragCommitted = false
                }
            }
        }
        self.isBatteryPopoverActive = false
        self.isMediaOutputPopoverActive = false
        self.edgeAutoOpenActive = false

        // Set the current view to tray if it contains files and the user enables openTrayByDefault
        // Otherwise, if the user has not enabled openLastTrayByDefault, set the view to home
        if !TrayStateViewModel.shared.isEmpty && Defaults[.openTrayByDefault] && Defaults[.showTrayView] {
            coordinator.currentView = .tray
        } else if !coordinator.openLastTabByDefault {
            // Ensure we land on an enabled view
            coordinator.currentView = Defaults[.showHomeView] ? .home : .tray
        }

        // Never leave the remembered tab pointed at a view the user has disabled
        // (e.g. "open last tab" kept it on Home after Home view was turned off).
        if coordinator.currentView == .home && !Defaults[.showHomeView] {
            coordinator.currentView = .tray
        } else if coordinator.currentView == .tray && !Defaults[.showTrayView] {
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
    // Pull-down deform/blur, applied ONCE around a whole content group (not
    // per-widget) so everything inside elongates together from the group's
    // own top edge instead of drifting apart from separately-anchored widgets.
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

    // Cancels liquidHorizontalGroup's ancestor lean with the reciprocal scale
    // around the same anchor, for content that has to stay pixel-stable
    // regardless of pull — the tray's drop-zone outlines are actual drag
    // targets, so shifting them sideways mid-drag reads as broken, not liquid.
    // Only valid for a view spanning the same width as the leaned ancestor
    // (true here: both sit in the same maxWidth-.infinity content slot).
    func liquidHorizontalGroupExempt(_ vm: KnotchViewModel) -> some View {
        self.scaleEffect(x: 1 / vm.liquidHorizontalStretchScale, y: 1, anchor: UnitPoint(x: vm.liquidHorizontalAnchorX, y: 0.5))
    }
}
