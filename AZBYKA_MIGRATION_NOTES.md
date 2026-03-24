# Azbyka Migration Notes

Updated: 2026-03-16

## Summary

This repo was switched from `orthocal.info` to Azbyka data. The initial Azbyka integration did not load because the no-auth fallback expected an outdated widget JSON schema and the full Azbyka API is not publicly readable without a valid key.

The app now loads from Azbyka again by preferring:

1. Full Azbyka API when a valid API key is present.
2. Public Azbyka day page HTML when no key is present.
3. Public Azbyka widget JSON as a minimal fallback.

## Changes Made

### 1. Replaced broken public Azbyka fallback

File: `RussianOrthodoxReader/Data/AzbykaAPIClient.swift`

- Updated widget decoding to the current live schema:
  - old expectation: `title`, `saints`, `holidays`, etc.
  - current live schema: `imgs`, `presentations`
- Added parsing of the public day page at:
  - `https://azbyka.ru/days/YYYY-MM-DD`
- Extracted from public HTML:
  - week/season title
  - fasting label
  - tone
  - saints/memorial text
  - reading references
- Added more defensive fallback behavior:
  - full API -> public page -> widget
- Fixed a crash in regex capture handling where a whole-match regex was incorrectly read as if it had capture group 1.

### 2. Forced refresh of bad cached Azbyka entries

File: `RussianOrthodoxReader/Data/LiturgicalRepository.swift`

- Bumped source version from `azbyka.v1` to `azbyka.v2`.
- Existing broken Azbyka cache entries are now treated as stale and refetched.

### 3. Extended reading reference parsing for Azbyka formats

File: `RussianOrthodoxReader/Data/ReadingReferenceParser.swift`

- Added support for comma continuations in the same chapter:
  - `Ин 21:1-11,15-17`
  - `Лк 1:39-49,56`
- Added support for implicit cross-chapter continuations:
  - `Притч 11:24-26,32-12:2`
- Added safer display ref generation for split references.

### 4. Added missing Azbyka-style Russian book aliases

File: `RussianOrthodoxReader/Data/BookAliasMapper.swift`

- Added aliases:
  - `1Сол` / `1сол`
  - `2Сол` / `2сол`

### 5. Updated Settings copy

File: `RussianOrthodoxReader/SettingsView.swift`

- Updated UI text so the no-key mode is described correctly.
- The app now indicates that it can use Azbyka’s public page even without an API key.

## Verification Performed

- Focused Swift typechecks passed for:
  - `AzbykaAPIClient.swift`
  - `OrthocalAPIClient.swift`
  - `ReadingReferenceParser.swift`
  - `BookAliasMapper.swift`
  - `LiturgicalCalendar.swift`
- A full `xcodebuild` in this workspace is still noisy because of an unrelated asset catalog / CoreSimulator issue already present in the environment.

## Remaining Log Notes

### Likely benign / not app-logic bugs

- `CoreData: debug: WAL checkpoint...`
  - Normal SQLite/Core Data maintenance.
- `tcp_input ... libusrtcp.dylib`
  - Network stack reset/noise; not evidence of a parsing bug by itself.
- `Tracking element window has a non-placeholder input view: (null)`
  - UIKit/internal OS log noise, likely related to text input or simulator behavior.

### Previously actionable app logs

- `[ReadingReferenceParser] unknown book alias: 1Сол`
  - Addressed by alias additions.
- `[ReadingReferenceParser] Unparseable token: ...`
  - Addressed for the Azbyka formats seen in this debugging session.

## Current State

- Daily content now loads from Azbyka.
- Broken cached blank Azbyka entries should refresh automatically.
- Remaining parser noise from the specific patterns seen today should be resolved by the latest parser changes.
