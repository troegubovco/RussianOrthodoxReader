# Implementation Changes Summary

This document summarizes the changes introduced during the reader-scroll and CloudKit sync work.

## Goals Covered

- Remove the SwiftUI reader warnings and preserve the full-book loading behavior.
- Keep chapter navigation exact: load the whole book, then move the reader to the chosen chapter.
- Add reliable cross-device reading-state sync with CloudKit.
- Keep sync privacy-first by limiting synced data and using the user's private CloudKit database only.
- Improve iPhone, iPad, and Mac behavior without splitting the app into different code paths where it was unnecessary.

## Reader Loading And Navigation

### Full-book loading contract

The loading logic in `ReaderViewModel` was changed so the app now builds the full set of sections for the selected book first and only then issues a scroll request for the selected chapter.

What changed:

- Added `ReaderScrollRequest` as an explicit view-model-to-view scroll command.
- Replaced the old `scrollToSectionID` string with `scrollRequest`.
- Removed the older two-phase "target chapter first, rest of book later" flow.
- Preserved the user requirement that the entire book is loaded and the reader lands on the requested chapter.

Files:

- `RussianOrthodoxReader/ViewModels/ReaderViewModel.swift`

### Reader scroll behavior

The reader view was migrated away from the old preference-key-driven scroll tracking.

What changed:

- Removed the old geometry preference pipeline and the state feedback loop that caused SwiftUI warnings.
- Added `ScrollPosition` for programmatic chapter jumps.
- Added `scrollTargetLayout()` so sections participate in scroll targeting.
- Tracked visible content using `onGeometryChange` for each section and `onScrollGeometryChange` for the scroll view.
- Added `ReaderScrollObservationCoordinator` to coalesce visibility updates and avoid per-frame state churn.
- Kept `pendingScrollTargetID` gating so the saved visible chapter does not jump to an earlier chapter while the requested chapter is still coming into view.
- Kept the persisted visible route flowing upward through `onVisibleRouteChange`.

Important note:

- The final implementation no longer uses `onScrollTargetVisibilityChange`. That API was part of the migration attempt, but it still produced `ScrollTargetVisibilityChange tried to update multiple times per frame` during fast scrolls. The final solution keeps `ScrollPosition` for chapter jumps but uses coalesced geometry-based visibility tracking instead.

Files:

- `RussianOrthodoxReader/ReaderView.swift`

## Reader Persistence And Resume Behavior

The reader container was updated so the active chapter route is always available when leaving reading mode, switching tabs, going into the background, or receiving a newer synced route from iCloud.

What changed:

- Added `activeReaderChapterRoute` tracking in `ContentView`.
- Persisted the most recent visible chapter when:
  - entering a reading route
  - switching tabs from the reader
  - backing out of the reader
  - moving the app to inactive/background
- Allowed cloud-updated reading routes to restore the reader when the user is not actively reading.
- Added a macOS-specific split-view tab shell so the app behaves naturally on Mac.

Files:

- `RussianOrthodoxReader/ContentView.swift`

## CloudKit Reading-State Sync

### New sync engine

A new reading-state sync module was added using `CKSyncEngine`.

What changed:

- Added `ReadingStateSyncService`.
- Added a minimal `ReadingState` model with:
  - `bookID`
  - `chapter`
  - `verse`
  - `lastModified`
  - `progressTimestamp`
  - `versionID`
- Stored reading progress in the user's private CloudKit database only.
- Used a dedicated private zone `ReadingStateZone`.
- Used one per-user record: `ReadingState/current`.
- Persisted the engine serialization locally so `CKSyncEngine` can resume efficiently.
- Debounced local writes before sending them to CloudKit.

Files:

- `RussianOrthodoxReader/ReadingStateSync.swift`

### Conflict resolution

Reading sync no longer uses "local always wins" or "cloud always wins".

What changed:

- Added timestamp-based last-write-wins reconciliation.
- Added a 60-second merge window.
- Within that merge window, the app prefers the furthest reading progress when the two updates are close together.
- When the server record is newer, local state is updated.
- When local state is newer, the resolved state is uploaded.
- Local `UserDefaults` now acts as a bootstrap/offline cache, not as a higher-priority source of truth.

Files:

- `RussianOrthodoxReader/ReadingStateSync.swift`
- `RussianOrthodoxReader/AppState.swift`

### CKSyncEngine delegate safety fix

After the initial sync engine integration, the app hit this runtime crash:

`Cannot await a call into CKSyncEngine from within a delegate callback`

What changed:

- Added a small scheduler actor for deferred engine calls.
- Moved delegate-triggered `sendChanges()` and `fetchChanges()` follow-up work out of the delegate callback path.
- Scheduled those follow-up operations through a detached task so `CKSyncEngine` keeps serial delegate guarantees.

Files:

- `RussianOrthodoxReader/ReadingStateSync.swift`

### App-state integration

`AppState` was updated to own the user-facing reading sync state.

What changed:

- Added:
  - `iCloudSyncEnabled`
  - `readingSyncPhase`
  - `readingSyncLastSyncDate`
  - `readingSyncErrorDescription`
- Added snapshot handling from `ReadingStateSyncService`.
- Added `syncReadingRouteToCloud(route:)`.
- Added `recordLocalReadingRoute(_:)`.
- Added `refreshFromCloud(force:)`.
- Ensured reading progress is refreshed on first app appearance and again on foreground transitions.
- Added background-task wrapping for the older CloudKit settings save path on iOS so app suspension does not cut off writes prematurely.

Files:

- `RussianOrthodoxReader/AppState.swift`

## Cloud Settings And Prayer Sync

The existing settings/prayer CloudKit path was retained and tightened up.

What changed:

- Added serialized CloudKit access in `CloudSyncService` so only one CloudKit settings operation runs at a time.
- Continued syncing the prayer-read date through the existing settings record.
- Added logging around settings load/save.

Files:

- `RussianOrthodoxReader/CloudSyncManager.swift`
- `RussianOrthodoxReader/AppState.swift`

## Settings UI

The Settings screen now exposes reading sync status and user control.

What changed:

- Added an iCloud sync toggle.
- Added explanatory privacy copy describing what is synced.
- Added a status title/detail section driven by the current sync phase.
- Made some small iOS/macOS compatibility adjustments around text input capitalization and navigation-bar behavior.

Files:

- `RussianOrthodoxReader/SettingsView.swift`

## App, Entitlements, And Background Delivery

The app entry point and project configuration were updated so CloudKit sync can work across products.

What changed:

- Registered for remote notifications on iOS and macOS app launch.
- Added a foreground refresh hook when the scene becomes active.
- Added iOS `remote-notification` background mode.
- Added a CloudKit entitlements file.
- Wired the entitlements file into the project build settings.

Files:

- `RussianOrthodoxReader/RussianOrthodoxReaderApp.swift`
- `RussianOrthodoxReader/Info.plist`
- `RussianOrthodoxReader/RussianOrthodoxReader.entitlements`
- `RussianOrthodoxReader.xcodeproj/project.pbxproj`

## Privacy Work

The sync feature was documented and constrained to a privacy-first shape.

What changed:

- Added `PrivacyInfo.xcprivacy`.
- Declared the required-reason API usage for `UserDefaults`.
- Added README documentation for:
  - synced fields
  - CloudKit scope
  - setup
  - testing
  - App Store privacy notes
- Kept reading sync limited to minimal progress metadata only.

Files:

- `RussianOrthodoxReader/PrivacyInfo.xcprivacy`
- `README.md`

## Cross-Platform Support

Several support changes were made so the same codebase works on iOS and macOS.

What changed:

- Added `PlatformTypes.swift` for `PlatformFont` and `PlatformColor`.
- Updated reader text rendering to use platform-specific font/color aliases.
- Switched some iOS-only UI paths behind platform checks.
- Added macOS reader hosting through `NavigationSplitView`.

Files:

- `RussianOrthodoxReader/PlatformTypes.swift`
- `RussianOrthodoxReader/ReaderView.swift`
- `RussianOrthodoxReader/ContentView.swift`
- `RussianOrthodoxReader/RussianOrthodoxReaderApp.swift`
- `RussianOrthodoxReader/SettingsView.swift`

## Swift 6 And Actor-Isolation Compatibility

The target is configured with default main-actor isolation, so several model and repository types needed to be explicitly marked as non-main-actor types.

What changed:

- Marked pure domain/model types as `nonisolated`.
- Marked the SQLite repository and protocol as `nonisolated`.
- Kept UI-facing state in `AppState` on the main actor.

Files:

- `RussianOrthodoxReader/BibleModels.swift`
- `RussianOrthodoxReader/LiturgicalCalendar.swift`
- `RussianOrthodoxReader/Data/BibleSQLiteRepository.swift`
- `RussianOrthodoxReader/AppState.swift`
- `RussianOrthodoxReader/ReadingStateSync.swift`

## Known Limitations

- Full `xcodebuild` still fails on the existing asset-catalog issue around `RussianOrthodoxReader 0.1.icon`.
- That asset issue is separate from the reader and sync changes.
- The app now supports near-real-time CloudKit delivery when the system allows it, but actual delivery latency still depends on device state, network availability, and Apple's push scheduling.

## Files Added

- `docs/implementation-changes-summary.md`
- `RussianOrthodoxReader/PlatformTypes.swift`
- `RussianOrthodoxReader/PrivacyInfo.xcprivacy`
- `RussianOrthodoxReader/ReadingStateSync.swift`
- `RussianOrthodoxReader/RussianOrthodoxReader.entitlements`

## Primary Files Updated

- `README.md`
- `RussianOrthodoxReader.xcodeproj/project.pbxproj`
- `RussianOrthodoxReader/AppState.swift`
- `RussianOrthodoxReader/CloudSyncManager.swift`
- `RussianOrthodoxReader/ContentView.swift`
- `RussianOrthodoxReader/Data/BibleSQLiteRepository.swift`
- `RussianOrthodoxReader/Info.plist`
- `RussianOrthodoxReader/LiturgicalCalendar.swift`
- `RussianOrthodoxReader/ReaderView.swift`
- `RussianOrthodoxReader/RussianOrthodoxReaderApp.swift`
- `RussianOrthodoxReader/SettingsView.swift`
- `RussianOrthodoxReader/ViewModels/ReaderViewModel.swift`
- `RussianOrthodoxReader/BibleModels.swift`
