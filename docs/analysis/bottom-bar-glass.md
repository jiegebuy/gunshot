# Google Photos bottom bar glass

Enable `GoToHP > Appearance > Google Photos · Liquid Glass` on iOS 26+.
The option defaults to off. Google Photos 7.92.0 is the audited host; later
versions must pass the same method contracts and live view-hierarchy checks.
Both targets are validated before either is changed. Exported diagnostics include
`bottomBarGlass` with availability, attached-bar count and a skip reason.
`attached` reports view installation, not a verified rendering result.

The segmented pill receives a public `UIGlassEffect` in a `UIVisualEffectView`,
with `UICornerConfiguration.capsuleConfiguration`. The control, shadow and
content backgrounds are cleared; the native segment children, selection and
gestures stay in place. Opt-out restores native backgrounds and elevation.

The search button uses its existing `phs_brandIconTonalGlassRound` styling.
Changing only `glassType` missed the native glass colors, shadows and opacity
configuration. Only the marked button's `isGlassEnabled` and material view's
`isGlass` gates are overridden. The host's `UIDesignRequiresCompatibility=true`
and global `M3CLiquidGlass` gate remain intact. Opt-out reapplies the original
`phs_brandIconTonalRound` styling plus Photos' saved normal/highlight backgrounds,
normal tint and elevation shadow; inactive glass-specific style tokens can remain
in the native button's tables until destruction or the next glass application.

7.92.0 static evidence (hashes and method ABIs: `objc/manifest.json` and indexes):

- `PHSTabBarController.createFloatingSearchButton` at `0x10005c46c` calls
  `phs_brandIconTonalRound`; its glass counterpart is at framework `0x101af34`.
- `gm3V11_brandM3CButtonGlassCommon` at `0x1afa7a4` sets type 1 and glass styling.
- `M3CMaterialGlassEffectView.updateGlassEffect` at `0x1bace58` maps type 1 to
  `UIGlassEffectStyleClear`; type 2 would use Regular. The old type-only patch
  bypassed the native styling sequence.

The existing UIKit smoke uses real glass APIs inside a compatibility-mode fixture
and fake Photos classes. It is not an injected Google Photos device test. Device
validation must cover opt-in/out, tab selection, search, light/dark appearance,
rotation and returning from a backgrounded app. No additional build target or
workflow is required.

Apple API references:
- https://developer.apple.com/videos/play/wwdc2025/284/
- https://developer.apple.com/documentation/uikit/uicornerconfiguration-c.class?language=objc
