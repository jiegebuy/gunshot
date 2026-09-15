# Google Photos bottom bar glass

Enable `GoToHP > Appearance > Google Photos · Liquid Glass` on iOS 26+.
The option defaults to off. Google Photos 7.92.0 is the audited host; later
versions must pass the same method contracts and live view-hierarchy checks.
Both targets are validated before either is changed. Exported diagnostics include
`bottomBarGlass` with availability, attached-bar count and a skip reason.
`attached` reports view installation, not a verified rendering result.

The visible left navigation deliberately does **not** insert a `UITabBarController`
or a foreign child view controller into Google Photos. Device validation on iOS
27 beta showed that `PHSTabBarController` treats its child controllers as Google
Photos navigation destinations and sends them private selectors such as
`destination`; inserting a stock `UITabBarController` therefore crashes with
`-[UITabBarController destination]: unrecognized selector`.

Instead, Gunshot renders the public UIKit Liquid Glass primitives directly in the
existing Google Photos floating bar. `GSPhotosGlassTabView` is a `UIControl` with
an outer capsule `UIVisualEffectView` backed by `UIGlassEffect`. Its frame is
centered on the Search control and forced to the same height as Search (minimum
56 pt), so the platter does not inherit the much thinner compact geometry that a
standalone/system tab bar used on the device. Three real `UIButton`s are placed
inside that capsule. The selected tab uses
`UIButtonConfiguration.glassButtonConfiguration`, producing the inner glass lens;
an unselected tab temporarily switches to the same glass configuration while it
is highlighted so UIKit owns the pressed/held glass response. The outer capsule
and inner selected/pressed glass are separate public UIKit effects rather than a
painted blur or a private `_UI*` view hierarchy.

Google Photos' original `PHSSegmentedControl` stays in its original `UIStackView`
as the navigation backend, but is made visually/accessibility-inactive while the
proxy mirrors its selection. Selecting a proxy tab writes the corresponding
`selectedSegmentIndex`. Audited 7.92 variants do not all agree about whether that
setter emits `UIControlEventValueChanged`, so the tap path temporarily installs a
probe and emits the event only if the host setter did not. A changed tab therefore
produces exactly one navigation event on either behavior; tapping the already
selected tab produces none. No global `UITabBarController` swizzle or separate
`GSPhotosTabBarEventBridge.m` is used.

The visible search control is a separate sibling `UIButton` built from
`UIButtonConfiguration.glassButtonConfiguration` and forwards `TouchUpInside`
to the untouched Google `M3CButton`. The original segmented and search controls
remain in Google's stack, so disabling the feature removes only the two proxy
controls and restores their saved alpha/interactivity/accessibility state; native
targets, gestures, colors, shadows and Material state are never rewritten by the
renderer.

Google Photos ships with `UIDesignRequiresCompatibility=true`, which suppresses
real Liquid Glass for the whole process. When this option is enabled, Gunshot
writes `com.apple.SwiftUI.IgnoreSolariumOptOut=true` before `UIApplicationMain`
on the next launch so UIKit uses the modern design while keeping the host
Info.plist unchanged. Changing the option therefore requires one Google Photos
restart.

7.92.0 static evidence (hashes and method ABIs: `objc/manifest.json` and indexes):

- `PHSTabBarController.createFloatingSearchButton` at `0x10005c46c` calls
  `phs_brandIconTonalRound`, assigns the search image/accessibility label, and
  registers a `TouchUpInside` target.
- `PHSSegmentedControl.numberOfSegments` is `q16@0:8`,
  `selectedSegmentIndex` is `q16@0:8`, and `setSelectedSegmentIndex:` is
  `v24@0:8q16` in the supplied 7.92.0 image.
- Static analysis suggested that `setSelectedSegmentIndex:` emits control event
  `0x1000` (`UIControlEventValueChanged`) after a changed selection. Device
  validation found builds where only the index changed, which is why the runtime
  tap probe measures actual behavior instead of relying on either assumption.

The UIKit smoke intentionally makes the fake Photos segmented control thinner
than Search, then verifies that the visible Liquid Glass proxy is still expanded
to Search height, has three tab buttons, keeps the selected state in sync, and
does not change `PHSTabBarController.childViewControllers`. It is not an injected
Google Photos device test. Device validation must still cover opt-in/out, tab
selection, Search, light/dark appearance, rotation, press-and-hold interaction
and returning from a backgrounded app.

Apple API references:
- https://developer.apple.com/videos/play/wwdc2025/284/
- https://developer.apple.com/documentation/uikit/uiglasseffect
- https://developer.apple.com/documentation/uikit/uibuttonconfiguration/glassbuttonconfiguration
