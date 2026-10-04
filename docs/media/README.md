# Screenshot provenance

All portfolio screenshots show fictional, synthetic financial data in the native app.
They were captured on a dedicated iPhone 17 Pro simulator running iOS 26.0,
in light mode at the simulator's native resolution, using Xcode 27.0.
No physical device, existing ledger or personal database was opened or modified.

The public-only `showcase` seed supplies the data through `LedgerExecutor`
and `CaptureProcessor`, using the same adapters/helpers as the other UI fixtures.
Demo seeding requires both a DEBUG build and in-memory storage.
The capture drafts were seeded; they were not produced by a live capture,
Vision recognition or Foundation Models session.

Launch arguments:

```text
-PaceInMemory YES
-PaceSeed showcase
-PaceFixedNow 2026-09-28T12:00:00+08:00
-PaceTimeZone Asia/Kuala_Lumpur
-pace.appearance 1
-AppleLanguages (en)
```

The status bar is overridden to 9:41, full battery and fixed signal indicators.
The seed uses a payday on the 25th, RM4,200 salary, 15% savings and RM1,150
aggregate commitments (fictional Rent RM900, Phone RM50 and Gym RM200).
The current product stores commitments as one aggregate planning value.
Salary is linked to its occurrence, so it is not counted again as expected income.
History contains fourteen days of generic/fictional expenses, salary and a refund.

| File | State |
|---|---|
| `home.png` | Within-plan Home, positive remaining budget, savings set aside |
| `needs-you.png` | Three attention examples plus the reviewable screenshot draft |
| `review-capture.png` | Seeded screenshot draft: Kedai Buku Ilmu, RM42.90, Shopping |
| `history.png` | Varied fictional entries grouped by date |

The attention examples include an ambiguous amount, a missing merchant and a
capture awaiting categorization. A fourth draft supports the Review capture image.
The app's normal navigation and review components render every screen.
No benchmark, Capture Lab, Shortcuts, Settings or microphone UI is shown.

`native/PaceUITests/ShowcaseScreenshotTests.swift` launches the safe seed,
verifies the within-plan state, navigates the screens and saves XCTest attachments.
The attachments are exported with `xcresulttool`; only the four approved PNGs
are retained here. PNG optimization is lossless. Each image is visually reviewed
for personal data, identifiers and notifications before committing.

Capture date: 4 October 2026. Financial date override: 28 September 2026.
The dedicated simulator is deleted after validation.

## Reproduce the capture

Create a fresh dedicated simulator and use the returned device identifier:

```sh
xcrun simctl create 'Pace Showcase' 'iPhone 17 Pro' com.apple.CoreSimulator.SimRuntime.iOS-26-0
xcrun simctl boot '<udid>'
xcrun simctl status_bar '<udid>' override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcodebuild test -project native/Pace.xcodeproj -scheme Pace \
  -destination 'platform=iOS Simulator,id=<udid>' \
  -only-testing:PaceUITests/ShowcaseScreenshotTests \
  -derivedDataPath /tmp/pace-showcase-dd \
  -resultBundlePath /tmp/pace-showcase.xcresult CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool export attachments \
  --path /tmp/pace-showcase.xcresult --output-path /tmp/pace-showcase-shots
xcrun simctl shutdown '<udid>'
xcrun simctl delete '<udid>'
```

The test supplies launch arguments itself; do not launch an App Intent.
The export manifest maps attachment names to PNG filenames.
Review each screen before copying the four matching images into this directory.
Use lossless PNG compression to keep each file below 600 KiB.
Remove the temporary result bundle and DerivedData when finished.

## Review limits

These images demonstrate rendering and review states, not live capture accuracy.
The UI suite and capture-package tests provide separate correctness evidence.
When refreshing the snapshot, rerun the seed and privacy review before replacing images.
