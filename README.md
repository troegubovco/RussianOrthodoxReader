# RussianOrthodoxReader
Синодальная Библия оффлайн с расширенным словарём, чтения дня по церковному календарю и молитва перед чтением. Готовьтесь к литургии осознанно.

## iCloud Reading Sync

The app now uses `CKSyncEngine` for reading-progress sync in the user's private CloudKit database.

- Synced fields: `bookID`, `chapter`, `verse`, `lastModified`, `progressTimestamp`, `versionID`
- Scope: private CloudKit database only
- Zone: custom private zone `ReadingStateZone`
- Record model: single per-user record `ReadingState/current`
- Conflict handling: timestamp-based last-write-wins, with a 60-second merge window that prefers the furthest reading progress
- Local behavior: UserDefaults remains the bootstrap/offline cache; remote data is reconciled on-device
- Background delivery: silent remote notifications via `CKSyncEngine` scheduling and iOS `remote-notification` background mode

## Setup

1. Enable the same iCloud container for every target: `iCloud.OG.RussianOrthodoxReader`
2. Keep push notifications enabled in entitlements for iOS and macOS builds
3. For iOS, keep the `remote-notification` background mode enabled
4. Make sure all device builds are signed into the same iCloud account
5. Use the Settings screen toggle to enable or disable iCloud reading sync

## Testing

1. Launch the app on two devices signed into the same iCloud account
2. Open different chapters on each device within a short interval and verify the newer/furthest state wins
3. Leave both apps active and confirm reading progress appears on the other device within roughly 30 seconds when online
4. Disable network on one device, advance reading progress, then restore network and confirm the deferred update syncs
5. Sign out of iCloud and confirm the synced local reading cache is cleared before a new account is used

## Privacy

- Synced data is minimized to reading progress only
- No public CloudKit database or user-to-user sharing is used
- Merge logic runs entirely on-device
- `PrivacyInfo.xcprivacy` declares the app's `UserDefaults` required-reason API usage

### App Store Connect App Privacy

Use the App Privacy questionnaire to declare:

- Data type: Reading Progress
- Purpose: App Functionality
- Linked to the user: Yes, via the user's private iCloud account
- Used for tracking: No
