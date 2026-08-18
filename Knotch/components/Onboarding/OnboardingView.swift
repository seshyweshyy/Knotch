//
//  OnboardingView.swift
//  Knotch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI
import AVFoundation

enum OnboardingStep {
    case welcome
    case cameraPermission
    case calendarPermission
    case remindersPermission
    case accessibilityPermission
    case musicPermission
    case uiModeSelection
    case finished
}

private let calendarService = CalendarService()

private let onboardingStepAnimation: Animation = .spring(response: 0.45, dampingFraction: 0.86)

private extension AnyTransition {
    // Wizard-style push: incoming step rises up from below while fading in,
    // the outgoing one continues rising out toward the top while fading out —
    // both stay horizontally centered, no left/right drift.
    static var onboardingPush: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(onboardingStepAnimation) {
                        step = .cameraPermission
                    }
                }
                .transition(.onboardingPush)

            case .cameraPermission:
                PermissionRequestView(
                    icon: Image(systemName: "camera.fill"),
                    title: "Enable Camera Access",
                    description: "Knotch includes a mirror feature that lets you quickly check your appearance using your camera, right from the notch. Camera access is required only to show this live preview. You can turn the mirror feature on or off at any time in the app.",
                    privacyNote: "Your camera is never used without your consent, and nothing is recorded or stored.",
                    iconColor: .gray,
                    onAllow: {
                        Task {
                            await requestCameraPermission()
                            withAnimation(onboardingStepAnimation) {
                                step = .calendarPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(onboardingStepAnimation) {
                            step = .calendarPermission
                        }
                    }
                )
                .transition(.onboardingPush)

            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: "Enable Calendar Access",
                    description: "Knotch can show all your upcoming events in one place. Access to your calendar is needed to display your schedule.",
                    privacyNote: "Your calendar data is only used to show your events and is never shared.",
                    iconColor: .red,
                    onAllow: {
                        Task {
                                await requestCalendarPermission()
                                withAnimation(onboardingStepAnimation) {
                                    step = .remindersPermission
                                }
                        }
                    },
                    onSkip: {
                            withAnimation(onboardingStepAnimation) {
                                step = .remindersPermission
                            }
                    }
                )
                .transition(.onboardingPush)

                case .remindersPermission:
                    PermissionRequestView(
                        icon: Image(systemName: "checklist"),
                        title: "Enable Reminders Access",
                        description: "Knotch can show your scheduled reminders alongside your calendar events. Access to Reminders is needed to display your reminders.",
                        privacyNote: "Your reminders data is only used to show your reminders and is never shared.",
                        iconColor: .orange,
                        onAllow: {
                            Task {
                                await requestRemindersPermission()
                                withAnimation(onboardingStepAnimation) {
                                    step = .accessibilityPermission
                                }
                            }
                        },
                        onSkip: {
                            withAnimation(onboardingStepAnimation) {
                                step = .accessibilityPermission
                            }
                        }
                    )
                    .transition(.onboardingPush)
                
            case .accessibilityPermission:
                PermissionRequestView(
                    icon: Image(systemName: "hand.raised.fill"),
                    title: {
                        if #available(macOS 27.0, *) {
                            "Enable Device Control and Data Access"
                        } else {
                            "Enable Accessibility Access"
                        }
                    }(),
                    description: {
                        if #available(macOS 27.0, *) {
                            "Device Control and Data Access permission is required to replace system notifications with the Knotch HUD. This allows the app to intercept media and brightness events to display custom HUD overlays."
                        } else {
                            "Accessibility access is required to replace system notifications with the Knotch HUD. This allows the app to intercept media and brightness events to display custom HUD overlays."
                        }
                    }(),
                    privacyNote: {
                        if #available(macOS 27.0, *) {
                            "Device Control and Data Access permission is used only to improve media and brightness notifications. No data is collected or shared."
                        } else {
                            "Accessibility access is used only to improve media and brightness notifications. No data is collected or shared."
                        }
                    }(),
                    iconColor: .blue,
                    titleFont: {
                        if #available(macOS 27.0, *) {
                            .title2
                        } else {
                            .title
                        }
                    }(),
                    onAllow: {
                        Task {
                            await requestAccessibilityPermission()
                            withAnimation(onboardingStepAnimation) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(onboardingStepAnimation) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(.onboardingPush)
                
            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
                        withAnimation(onboardingStepAnimation) {
                            step = .uiModeSelection
                        }
                    }
                )
                .transition(.onboardingPush)

            case .uiModeSelection:
                UIModeSelectionView(
                    onContinue: {
                        withAnimation(onboardingStepAnimation) {
                            KnotchViewCoordinator.shared.firstLaunch = false
                            step = .finished
                        }
                    }
                )
                .transition(.onboardingPush)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
                    .transition(.onboardingPush)
            }
        }
        .frame(width: 400, height: 600)
        .clipped()
        // Declarative fallback for the window's rounded corners, since the AppKit
        // layer.cornerRadius set in showOnboardingWindow can get silently dropped.
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    // MARK: - Permission Request Logic

    func requestCameraPermission() async {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestCalendarPermission() async {
        _ = try? await calendarService.requestAccess(to: .event)
    }

    func requestRemindersPermission() async {
        _ = try? await calendarService.requestAccess(to: .reminder)
    }
    
    func requestAccessibilityPermission() async {
        _ = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
    }
}
