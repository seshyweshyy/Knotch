# Settings, focus and playback-label fixes — 22 October 2026

## Focus ownership

`KnotchSkyLightWindow` previously called `makeKey()` when an app activated and held key status across a notch/HUD presentation. A nonactivating panel can still take keyboard routing from another app. Passive overlays now refuse key status and request a refresh of the known glass view through the existing appearance notification instead. The main overlay now shares the lock-screen appearance-only lease (`acquireKeyAppearance` / `acquireMainAppearance` and forced active-control appearance). The lease is acquired when visible and released on order-out/close, without making the real window key or main. This follow-up corrects the inactive/frosted material regression observed after removing the old focus grab.

The updater also no longer activates on each phase change or background update discovery. Only the explicit user-initiated check requests activation; later phases update the existing window without reclaiming focus.

Opening Settings still explicitly activates its normal window. This happens once, synchronously, instead of queuing a second activation that could run after the user switches away.

## Settings performance without a redesign

- Settings pages observe a small preference snapshot instead of all HUD/progress/animation publications from the coordinator. Bursts coalesce and unchanged snapshots do not invalidate the page. UserDefaults notifications also refresh changes made elsewhere.
- Removed unused notch-model and coordinator subscriptions.
- Accent changes update the tint environment without replacing the entire settings tree and losing view identity, scroll position or local state.
- All appearance cards share one wallpaper thumbnail bounded to 512 pixels. The cache refreshes when the wallpaper URL changes, instead of loading separate desktop-sized images per card.
- Camera availability uses the manager's existing published state instead of running camera discovery during view construction.
- The initial window size matches the existing 700 × 620 content layout. Lazy loading and teardown on close are retained.

The sidebar, page structure, controls, labels, card sizes and selection borders are retained.

## Glass appearance cards

The notch cards no longer draw a second blurred wallpaper image inside the notch or cover it with an opaque black base. On macOS 26+, the material is native SwiftUI clear glass with the same notch silhouette. Semi-glass keeps its black-to-clear overlay and now follows the actual glass-amount preference; full glass retains its translucent dark overlay.

The mini-widget Glass Capsules card also uses native clear glass instead of thin/frosted material. Floating Text keeps its existing treatment. Older macOS releases retain material fallbacks.

## Progress timestamps

Elapsed and remaining labels reserve a monospaced layout footprint based on the track's duration format, including colons and the remaining-time sign. Text-content replacement uses an identity transition, while label geometry inherits the same opening/reveal transaction as the rest of the player. The earlier unconditional transaction override was removed after it caused a visible mismatch even with playback paused. Each label is composited as one unit. The fill animation remains continuous.

## Validation

- Optimized macOS Release build and launch: passed.
- `script/test_settings_observation.sh`: passed against the production observer with a minimal coordinator fixture. Checks 100 HUD changes with zero settings invalidations, one invalidation for a preference burst, binding propagation, suppression of duplicate/transient changes, and refresh after an external defaults notification.
- Xcode project syntax and whitespace checks: passed.
- No runtime visual, keyboard-routing, frame-time or energy measurement was available. Confirm typing remains in another app during passive HUD/open/close events; verify settings controls and search still accept focus; inspect both glass card groups and timestamp stability while music is playing, in standard and compact layouts.
