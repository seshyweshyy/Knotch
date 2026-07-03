//
//  ContentView.swift
//  Knotch
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

struct MusicLiveActivity: View {
    @ObservedObject var musicManager = MusicManager.shared
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @Default(.coloredSpectrogram) var coloredSpectrogram
    @Default(.sneakPeekStyles) var sneakPeekStyles
    @Default(.useMusicVisualizer) var useMusicVisualizer

    let albumArtNamespace: Namespace.ID

    @State private var displayedArt: NSImage = MusicManager.shared.albumArt
    @State private var rotationDegrees: Double = 0

    var body: some View {
        HStack {
            Image(nsImage: displayedArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music)
                        ? vm.effectiveClosedNotchHeight - 4   // slightly bigger during sneak peek
                        : vm.effectiveClosedNotchHeight - 12),
                    height: max(0, (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music)
                        ? vm.effectiveClosedNotchHeight - 4
                        : vm.effectiveClosedNotchHeight - 12)
                )
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: coordinator.sneakPeek.show)
                .rotation3DEffect(
                    .degrees(rotationDegrees),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.4
                )
                .onChange(of: musicManager.artFlipSignal) { _, signal in
                    let dir: Double = signal.direction == .forward ? 1 : -1

                    withAnimation(.easeIn(duration: 0.15)) {
                        rotationDegrees = dir * 90
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        displayedArt = signal.art
                        rotationDegrees = dir * -90
                        withAnimation(.easeOut(duration: 0.15)) {
                            rotationDegrees = 0
                        }
                    }
                }

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: coloredSpectrogram
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && sneakPeekStyles == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    coloredSpectrogram
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && sneakPeekStyles == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && sneakPeekStyles == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    ZStack {
                        Image(nsImage: displayedArt)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 22)
                            .blur(radius: 5)
                            .saturation(1.1)
                            .brightness(0.01)
                        Color.white.opacity(0.05)
                            .frame(width: 36, height: 22)
                    }
                    .mask {
                        AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                            .frame(width: 24, height: 14)
                    }
                    .frame(width: 24, height: 14)
                    .clipped()
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(0, vm.effectiveClosedNotchHeight - 12),
                height: max(0, vm.effectiveClosedNotchHeight - 12),
                alignment: .center
            )
        }
        .frame(
            height: (coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music)
                ? vm.effectiveClosedNotchHeight + 8
                : vm.effectiveClosedNotchHeight,
            alignment: .center
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: coordinator.sneakPeek.show)
    }
}

private struct BatteryNotchBanner: View {
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @EnvironmentObject var vm: KnotchViewModel

    private let bannerWidth: CGFloat = 280
    private let bannerContentHeight: CGFloat = 60

    private enum BannerKind: Equatable {
        case lowBattery
        case fullBattery
        case generic
    }

    private var kind: BannerKind {
        if batteryModel.levelBattery <= 20 && !batteryModel.isCharging && !batteryModel.isPluggedIn {
            return .lowBattery
        } else if batteryModel.levelBattery == 100 && (batteryModel.isCharging || batteryModel.isPluggedIn) {
            return .fullBattery
        } else {
            return .generic
        }
    }

    @State private var pulse = false
    @State private var showBatteryIndicator = false
    @State private var changeBatteryIndicator = true

    var body: some View {
        Group {
            if kind == .generic {
                genericBanner
            } else {
                standardBanner
            }
        }
        .onAppear(perform: prepareAnimations)
        .onChange(of: kind) { _, _ in prepareAnimations() }
    }

    // Original slim pill — still used for the Low Power Mode toggle message
    private var genericBanner: some View {
        HStack(spacing: 0) {
            HStack {
                Text(batteryModel.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 110, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 40)

            HStack {
                KnotchBatteryView(
                    batteryWidth: 30,
                    isCharging: batteryModel.isCharging,
                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                    isPluggedIn: batteryModel.isPluggedIn,
                    levelBattery: batteryModel.levelBattery,
                    isForNotification: true
                )
            }
            .frame(width: 76, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    // Takeover banner for low/full battery
    private var standardBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: kind == .lowBattery ? 2 : 3) {
                title
                description
            }
            .padding(.leading, kind == .lowBattery ? 40 : 35)
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            indicator
                .padding(.leading, 15)
                .padding(.trailing, kind == .lowBattery ? 45 : 40)
        }
        .frame(width: bannerWidth, height: bannerContentHeight)
        .padding(.top, vm.effectiveClosedNotchHeight)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var title: some View {
        HStack(spacing: 5) {
            Text(verbatim: kind == .lowBattery ? "Battery Low" : "Full Battery")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            Text("\(Int(batteryModel.levelBattery))%")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind == .lowBattery
                    ? (batteryModel.isInLowPowerMode ? .yellow : .red)
                    : (batteryModel.isInLowPowerMode ? .yellow : .green))
        }
    }

    @ViewBuilder
    private var description: some View {
        switch kind {
        case .lowBattery:
            if batteryModel.isInLowPowerMode {
                (
                    Text(verbatim: "Low Power Mode enabled,")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10, weight: .medium))
                    +
                    Text(verbatim: "\nit is recommended to charge it.")
                        .foregroundColor(.gray.opacity(0.6))
                        .font(.system(size: 10, weight: .medium))
                )
                .lineLimit(2)
            } else {
                Text(verbatim: "Turn on Low Power Mode or it\nis recommended to charge it.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray.opacity(0.6))
                    .lineLimit(2)
            }
        case .fullBattery:
            Text(verbatim: "Your Mac is fully charged.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray.opacity(0.6))
                .lineLimit(1)
        case .generic:
            EmptyView()
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch kind {
        case .lowBattery:
            if batteryModel.isInLowPowerMode {
                yellowLowIndicator
            } else {
                redLowIndicator
            }
        case .fullBattery:
            if showBatteryIndicator {
                if batteryModel.isInLowPowerMode {
                    yellowFullIndicator
                        .transition(.opacity.combined(with: .scale))
                } else {
                    greenFullIndicator
                        .transition(.opacity.combined(with: .scale))
                }
            } else {
                magSafeIndicator
                    .transition(.opacity.combined(with: .scale))
            }
        case .generic:
            EmptyView()
        }
    }

    private var redLowIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.red.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.4))
                    .frame(width: 40, height: 24)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
            .padding(.trailing, 5)

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.gradient)
                .frame(width: 8, height: 14)
                .opacity(pulse ? 1 : 0.3)
                .offset(x: -15)

            RoundedRectangle(cornerRadius: 30)
                .stroke(Color.red.opacity(0.9), lineWidth: 1.5)
                .frame(width: pulse ? 8 : 30, height: pulse ? 14 : 32)
                .offset(x: -15)
                .opacity(pulse ? 0.3 : 1)
        }
    }

    private var yellowLowIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.yellow.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 40, height: 24)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
            .padding(.trailing, 5)

            RoundedRectangle(cornerRadius: 8)
                .fill(.yellow.gradient)
                .frame(width: 8, height: 14)
                .offset(x: -15)
        }
    }

    private var greenFullIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.green.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.green.opacity(0.4))
                    .frame(width: 44, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.gradient)
                            .frame(width: 34, height: 14)
                            .opacity(pulse ? 1 : 0.4)
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(.green.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
        }
    }

    private var yellowFullIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.yellow.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 44, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.yellow.gradient)
                            .frame(width: 34, height: 14)
                            .opacity(pulse ? 1 : 0.4)
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
        }
    }

    private var magSafeIndicator: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.gray.opacity(0.15))
                .frame(width: 30, height: 5)

            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.gray.opacity(0.2).gradient)
                    .frame(width: 30, height: 40)

                Circle()
                    .fill(changeBatteryIndicator ? .orange : .green)
                    .shadow(color: changeBatteryIndicator ? .orange : .green, radius: 5)
                    .frame(width: 5, height: 5)
            }

            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 3, height: 32)
        }
    }

    private func prepareAnimations() {
        pulse = false
        showBatteryIndicator = kind == .fullBattery
        changeBatteryIndicator = true

        switch kind {
        case .generic:
            break
        case .lowBattery:
            if !batteryModel.isInLowPowerMode {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        case .fullBattery:
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.spring(duration: 0.4)) {
                    showBatteryIndicator = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.spring(duration: 0.2)) {
                    changeBatteryIndicator = false
                }
            }
        }
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared

    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?
    
    @State private var hasTriggeredSwipe = false
    @State private var lockedView: NotchViews? = nil

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false
    
    @State private var isUnlockAnimating: Bool = false
    @EnvironmentObject private var lockAnimationHost: LockAnimationHost
    
    @State private var bluetoothHUDExpanded: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
            vm.notchState == .open ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
        }

    private var currentNotchShape: NotchShape {
        let batteryModel = BatteryStatusViewModel.shared
        let isExpandedBatteryBanner = coordinator.expandingView.type == .battery
            && coordinator.expandingView.show
            && Defaults[.showPowerStatusNotifications]
            && ((batteryModel.levelBattery <= 20 && !batteryModel.isCharging && !batteryModel.isPluggedIn)
                || (batteryModel.levelBattery == 100 && (batteryModel.isCharging || batteryModel.isPluggedIn)))

        return NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: vm.notchState == .open
                ? cornerRadiusInsets.opened.bottom
                : coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music
                    ? 22
                    : coordinator.sneakPeek.show && coordinator.sneakPeek.type == .bluetoothAudio
                        ? bluetoothHUDExpanded ? 28 : cornerRadiusInsets.closed.bottom + 4
                            : isExpandedBatteryBanner
                                ? 28
                                : cornerRadiusInsets.closed.bottom
        )
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if vm.notchState == .closed && (vm.isScreenLocked || isUnlockAnimating) {
            chinWidth += 60
        } else if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .bluetoothAudio
            && vm.notchState == .closed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) - 10)
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? cornerRadiusInsets.opened.top
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: 6
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(
                        width: vm.notchState == .open ? vm.notchSize.width : nil,
                        height: vm.notchState == .open ? vm.notchSize.height : nil
                    )
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !self.vm.isMediaOutputPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.isMediaOutputPopoverActive) {
                        if !vm.isMediaOutputPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isMediaOutputPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.isScreenLocked) { _, newLocked in
                        if !newLocked {
                            isUnlockAnimating = true
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("Version \(version)")
                                .font(.footnote)
                        }
                        
                        Button {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        } label: {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                        
                        Divider()
                        
                        Button {
                            NSApp.terminate(nil)
                        } label: {
                            Label("Quit Knotch", systemImage: "xmark.rectangle")
                        }
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: vm.notchState == .open ? .center : .leading) {
            VStack(alignment: vm.notchState == .open ? .center : .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    // Locked state — show lock icon first, before any other content
                    let hudIsActive = coordinator.sneakPeek.show
                        && coordinator.sneakPeek.type != .music
                        && coordinator.sneakPeek.type != .bluetoothAudio
                        && vm.notchState == .closed

                    if (vm.isScreenLocked || isUnlockAnimating) && !hudIsActive {
                        HStack(spacing: 0) {
                            LockNotchOverlay(isLocked: vm.isScreenLocked, isUnlockAnimating: $isUnlockAnimating, host: lockAnimationHost)
                                .allowsHitTesting(false)
                                .padding(.leading, cornerRadiusInsets.closed.bottom - 10)
                            Spacer()
                        }
                        .frame(width: vm.closedNotchSize.width + 50, height: vm.effectiveClosedNotchHeight)
                    } else {
                        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                        {
                            BatteryNotchBanner()
                        } else if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .bluetoothAudio && vm.notchState == .closed {
                            BluetoothHUDView(
                                icon: coordinator.sneakPeek.icon,
                                deviceName: coordinator.sneakPeek.deviceName,
                                batteryFraction: coordinator.sneakPeek.value,
                                isExpanded: $bluetoothHUDExpanded
                            )
                            .environmentObject(vm)
                            .transition(.opacity)
                        } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && (coordinator.sneakPeek.type != .bluetoothAudio) && vm.notchState == .closed {
                            InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                                .transition(.opacity)
                        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                            MusicLiveActivity(albumArtNamespace: albumArtNamespace)
                                .frame(alignment: .center)
                        } else if vm.notchState == .open {
                            KnotchHeader()
                                .frame(height: max(24, vm.effectiveClosedNotchHeight))
                                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                        } else {
                            Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                        }
                        
                        if coordinator.sneakPeek.show {
                            if coordinator.sneakPeek.type == .bluetoothAudio && vm.notchState == .closed {
                            } else if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && (coordinator.sneakPeek.type != .bluetoothAudio) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                                SystemEventIndicatorModifier(
                                    eventType: $coordinator.sneakPeek.type,
                                    value: $coordinator.sneakPeek.value,
                                    icon: $coordinator.sneakPeek.icon,
                                    sendEventBack: { newVal in
                                        switch coordinator.sneakPeek.type {
                                        case .volume:
                                            VolumeManager.shared.setAbsolute(Float32(newVal))
                                        case .brightness:
                                            BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                        default:
                                            break
                                        }
                                    }
                                )
                                .padding(.bottom, 10)
                                .padding(.leading, 4)
                                .padding(.trailing, 8)
                            }
                            // Old sneak peek music
                            else if coordinator.sneakPeek.type == .music {
                                if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                    HStack(alignment: .center) {
                                        Image(systemName: "music.note")
                                        GeometryReader { geo in
                                            MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                        }
                                    }
                                    .foregroundStyle(.gray)
                                    .padding(.bottom, 10)
                                }
                            }
                        }
                    }
                }
            }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    }
                }
                .onChange(of: coordinator.currentView) { _, newView in
                    if vm.notchState == .open {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                            vm.notchSize = newView == .home ? vm.computedHomeSize : openNotchSize
                        }
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.knotchShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        guard !vm.isScreenLocked else { return }
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  !vm.isScreenLocked,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !self.vm.isMediaOutputPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {

        if vm.notchState == .open {
            guard !vm.isHoveringCalendar else { return }

            if phase == .began {
                hasTriggeredSwipe = false
                lockedView = nil
                return
            }

            if hasTriggeredSwipe {
                if phase == .ended {
                    gestureProgress = .zero
                }
                return
            }

            if phase == .ended {
                withAnimation(animationSpring) { gestureProgress = .zero }
                return
            }

            if Defaults[.swipeToCycleViews] {
                let destination: NotchViews = coordinator.currentView == .home ? .shelf : .home
                let destinationEnabled = destination == .home
                    ? Defaults[.showHomeView]
                    : Defaults[.showShelfView]
                if destinationEnabled {
                    lockedView = destination
                    hasTriggeredSwipe = true
                    if Defaults[.enableHaptics] { haptics.toggle() }
                    withAnimation(animationSpring) {
                        coordinator.currentView = destination
                    }
                }
            }

            return
        }

        // CLOSED → OPEN (unchanged)
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] { haptics.toggle() }
            withAnimation(animationSpring) { gestureProgress = .zero }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = KnotchViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
