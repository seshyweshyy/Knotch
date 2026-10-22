# Animation audit — 22 October 2026

## Scope and evidence

Scanned all 181 Swift source files in Knotch. The inventory below covers all 60 files containing animation, transition, timeline, emitter, or animatable-shape code. Reviewed the shared shell, gesture and row-family choreography, AirDrop/Bluetooth phases, music artwork and playback, timer/bubble, onboarding, tray, tab and popover paths in detail. Calendar, settings and secondary-window animation sites were inspected for identity, animation scoping and delayed-work hazards.

This is a code audit with build, launch and shape validation. It is not proof of zero dropped frames across all hardware, display modes, or interactions. No before/after frame-time, GPU, CPU or energy profile was captured. The saved `alcove-research/REPORT.md` was consulted as reference; REA and a fresh DynamicLakePro/Alcove runtime comparison were unavailable.

## Changes, in priority order

| Area | Problem | Change |
| --- | --- | --- |
| AirDrop and Bluetooth shell | Parent layout switched between nil and concrete height; the transform anchor also changed during the morph | Concrete compact/expanded height endpoints and a stable top anchor, with one explicit phase transaction driving child and parent |
| Bluetooth media | The phase switch destroyed and recreated the device video player | One persistent overlay moves and resizes the same player |
| AirDrop content | Filesystem type/icon queries happened in view construction; thumbnail loading only reacted to changes after mounting | File-keyed, lifecycle-managed loading, stored metadata/icon, cancellation and stale-result checks; initial files load too |
| Hidden compact content | Permanently mounted music content kept waveform consumers, playback ticks and motion video alive while closed | Visibility gates the waveform clock consumer, progress timeline/continuous fill and video player; motion-art lookup is cancelled/restarted through a task key |
| Hidden timer bubble | Invisible bubble kept a 30 Hz ring timeline running | Propagate visibility to the ring and pause its timeline while merged |
| Full-panel reveal | 30pt animated blur covered the entire opening/closing panel | One shared 12pt reveal blur, preserving the existing scale/fade choreography |
| Marquee | Moving text was limited to 30 Hz and reconstructed styled text in the timeline closure | Up to 60 Hz while scrolling; build the text pair outside the per-frame callback; stop automatic scrolling for Reduce Motion |
| Artwork across all music surfaces | Fixed-delay cleanup could install old artwork or clear newer motion video | Completion-based sequencing with generation/URL guards |
| Song-label reveal | A guessed deadline drove the value swap; callbacks survived disappearance | Animation completion drives the swap; disappearance invalidates pending callbacks; Reduce Motion updates directly |
| Lottie visualizer | Parent redraws could duplicate URL loads; late responses could replace a newer animation | Record requested URL before loading, reject stale responses, stop on dismantle, and pause for Reduce Motion |
| Volume/brightness Lottie | Parent redraws restarted the same in-flight segment | Coordinator remembers the target; only a changed target retargets playback |
| Tab selection | Both selected and hidden backgrounds registered as sources for one matched geometry ID | Only the selected capsule registers the geometry source |
| Popover dismissal | Closing during fade-in restarted from full opacity | Fade out from presentation-layer opacity |
| Button feedback | Mirrored toggled press state could diverge; extreme damping exaggerated bounce | Derive scale directly from the actual press; use a restrained spring; respect Reduce Motion |
| Skip feedback | Guessed timeout reset the icon independently of actual settling | Reset at animation completion in a nonanimated transaction |
| Onboarding/startup | Delayed entrances could outlive their view; cancelled startup work could still finish | Lifecycle-managed cancellable entrance tasks and cancellation checks before startup continuation |
| Rounded shell geometry | Bottom radius snapped and could exceed small frames | Animatable radius clamped to the current rectangle |
| Accessibility | Most shared animations ignored Reduce Motion | Disable animated notch transactions, stop decorative waveform/timer/skeleton/marquee motion, use static Bluetooth symbols and direct artwork updates |

## Existing optimizations retained

- Shared energy-aware visualizer clock with 30 Hz normal and 15 Hz constrained cadence; no blanket frame-rate increase for waveforms.
- Continuous compositor playback fill, with occasional timestamp updates rather than full view rebuilds on every display frame.
- Idle timer teardown and common-run-loop timers.
- AVPlayerLooper and bounded video decoding resolution, including existing dismantle cleanup.
- Cached progressive-blur masks and in-process backdrop geometry; no new per-frame window repositioning.
- Existing row-family generation guards, hover debounce, fixed resting layout widths and display-specific corner geometry.
- Stable identities for tray, timer, calendar and settings collections. Avoided rewriting native scrolling or adding new animation dependencies without a demonstrated defect.

## Verification

- Optimized Release build: passed, macOS destination, signing disabled for local verification.
- App launch/process verification: passed through `script/build_and_run.sh --verify`.
- Actual shape geometry: 4,536 cases passed through `script/test_animation_geometry.sh`. Covers zero/tiny/compact/expanded frames, negative and oversized radii, finite coordinates and containment in the proposed rectangle.
- Synthetic AirDrop progress publisher: executed through Foundation's public progress API without creating a file or sending a transfer. This verifies the probe ran, not that the app rendered each phase; no UI assertion was available.
- Attempted top-center screen captures for compact/expanded/collapsed phases: unavailable (`could not create image from rect`). No screenshot or visual sign-off was obtained.
- Shell script syntax and `git diff --check`: passed.
- No Xcode unit-test target exists in the project; the geometry checks compile the actual production shape files as a standalone executable.

## Runtime validation still required

Do not infer measured smoothness from a successful build or static screenshots. Check these on the actual display, ideally in a Release Instruments capture:

1. Real AirDrop: progress completion, missing/late file URL, thumbnail arrival, hover pause/resume, direct dismissal while expanded, and a new transfer arriving during collapse.
2. Bluetooth: symbol and video styles, unknown battery, repeated connections and dismissal mid-sequence.
3. Notch and island appearance; standard and compact layouts; opaque, semi-glass and full-glass surfaces; multiple displays and changed display scale.
4. Rapid open/close and reversals, horizontal/vertical pull, HUD value bounds, HUD-to-music/timer handoffs and split/merge.
5. Rapid track skipping during a flip, late artwork/motion-art responses, paused playback, hidden compact pages and lock/unlock.
6. Tray drag enter/exit flapping, calendar date scrolling, timer completion during another activity, onboarding navigation and popover dismissal during insertion.
7. Reduce Motion changes, Low Power Mode, thermal pressure, 60 Hz/120 Hz displays and idle CPU/energy after animations settle.

## Complete static inventory

Every file below was included in the static animation-site scan. This list is coverage evidence for the scan, not a claim that every interaction has been exercised at runtime.

- `Knotch/ContentView.swift`
- `Knotch/KnotchApp.swift`
- `Knotch/KnotchViewCoordinator.swift`
- `Knotch/animations/HelloAnimation.swift`
- `Knotch/components/BottomRoundedRectangle.swift`
- `Knotch/components/Calendar/KnotchCalendar.swift`
- `Knotch/components/Calendar/MonthGridView.swift`
- `Knotch/components/EmptyState.swift`
- `Knotch/components/HoverButton.swift`
- `Knotch/components/Live activities/AirDropReceiveHUD.swift`
- `Knotch/components/Live activities/BatteryView.swift`
- `Knotch/components/Live activities/BluetoothHUDView.swift`
- `Knotch/components/Live activities/ClosedNotchRowContent.swift`
- `Knotch/components/Live activities/InlineHUD.swift`
- `Knotch/components/Live activities/MarqueeTextView.swift`
- `Knotch/components/Live activities/MultiActivityViews.swift`
- `Knotch/components/Live activities/OpenNotchHUD.swift`
- `Knotch/components/Live activities/SystemEventIndicatorModifier.swift`
- `Knotch/components/LockScreen/LockScreenLyrics.swift`
- `Knotch/components/LockScreen/LockScreenMiniWidgetRowWindow.swift`
- `Knotch/components/Music/CompactMusicPlayerView.swift`
- `Knotch/components/Music/ExpandedAlbumArtView.swift`
- `Knotch/components/Music/LiquidGlassMusicWidget.swift`
- `Knotch/components/Music/LiquidGlassWidgetWindow.swift`
- `Knotch/components/Music/MusicVisualizer.swift`
- `Knotch/components/Notch/KnotchContrastOutline.swift`
- `Knotch/components/Notch/KnotchHeader.swift`
- `Knotch/components/Notch/KnotchLiquidGlass.swift`
- `Knotch/components/Notch/KnotchProgressiveBlur.swift`
- `Knotch/components/Notch/LockNotchOverlay.swift`
- `Knotch/components/Notch/NotchHomeView.swift`
- `Knotch/components/Notch/NotchShape.swift`
- `Knotch/components/Onboarding/MusicControllerSelectionView.swift`
- `Knotch/components/Onboarding/OnboardingAnimations.swift`
- `Knotch/components/Onboarding/OnboardingView.swift`
- `Knotch/components/Onboarding/SparkleView.swift`
- `Knotch/components/Onboarding/UIModeSelectionView.swift`
- `Knotch/components/Settings/MusicSlotConfigurationView.swift`
- `Knotch/components/Settings/SettingsView.swift`
- `Knotch/components/Tabs/TabSelectionView.swift`
- `Knotch/components/TestView.swift`
- `Knotch/components/Timer/LiquidGlassTimerWidgetWindow.swift`
- `Knotch/components/Timer/TimerExpandedCard.swift`
- `Knotch/components/Timer/TimerListView.swift`
- `Knotch/components/Timer/TimerSliderView.swift`
- `Knotch/components/Tray/Views/CompactFileConverterView.swift`
- `Knotch/components/Tray/Views/CompactTrayView.swift`
- `Knotch/components/Tray/Views/FileShareView.swift`
- `Knotch/components/Tray/Views/TrayItemView.swift`
- `Knotch/extensions/BlurRevealModifier.swift`
- `Knotch/extensions/Button+Bouncing.swift`
- `Knotch/extensions/NotchTransition.swift`
- `Knotch/managers/LocalSendDevicePickerWindowManager.swift`
- `Knotch/managers/MediaOutputPopoverWindowManager.swift`
- `Knotch/managers/MusicManager.swift`
- `Knotch/managers/TimerManager.swift`
- `Knotch/managers/UpdateFoundView.swift`
- `Knotch/models/BatteryStatusViewModel.swift`
- `Knotch/models/KnotchViewModel.swift`
- `Knotch/sizing/matters.swift`
