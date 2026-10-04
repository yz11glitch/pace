# Native Pace

SwiftUI app for iOS 26, with a pure domain core and a GRDB/SQLite store.
This is an active-development sanitized snapshot.

- `PaceApp/`: views, App Intents, Vision OCR, category suggestion.
- `Packages/PaceCore/`: deterministic financial and capture rules.
- `Packages/PaceStore/`: persistence, review, undo and backups.
- `PaceUITests/`: simulator navigation and capture tests.

Open `Pace.xcodeproj` in Xcode 26 or later. Device builds need your own
bundle identifier prefix and signing team in `Config/Pace.xcconfig`.

From the repository root:

```sh
cd native
xcodebuild build -project Pace.xcodeproj -scheme Pace -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
(cd Packages/PaceCore && swift test)
(cd Packages/PaceStore && swift test)
```

For UI tests, use an installed iOS 26 simulator, such as iPhone 17 Pro.

```sh
xcodebuild test -project Pace.xcodeproj -scheme Pace -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

Safe demo launch arguments: `-PaceInMemory YES -PaceSeed demo`.
Demo seeding requires a DEBUG build and an in-memory database.
To fix time: `-PaceFixedNow 2026-09-28T12:00:00+08:00 -PaceTimeZone Asia/Kuala_Lumpur`.
