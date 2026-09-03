import Foundation

#if DEBUG
/// DEBUG-only launch hooks for driving the app from outside a UI automation
/// harness — this project has none, so verification of things like "does
/// Bible search actually find X" or "does the reader land on the right
/// verse" is done via `xcrun simctl launch … SINODAL_OPEN_…=…` plus
/// `xcrun simctl io … screenshot`, read back with the Read tool. Values are
/// read once, at process start, from `ProcessInfo.processInfo.environment`
/// (set via `simctl launch --setenv` or the Xcode scheme's environment
/// variables). See search_design.md §5 step 14 / the Bible search work log.
///
///  * `SINODAL_OPEN_SEARCH=<query>` — switches to the «Библия» tab and opens
///    `BibleSearchView` pre-filled with `<query>`, already searched.
///  * `SINODAL_OPEN_VERSE=<book>:<chapter>:<verse>` — e.g.
///    `SINODAL_OPEN_VERSE=jhn:3:16` — opens the reader directly at that verse,
///    verse briefly highlighted. The book token goes through
///    `BookAliasMapper`, so both English aliases ("jhn") and this app's
///    internal book ids ("joh") work.
enum DebugLaunchHooks {
    static let openSearchQuery: String? = {
        guard let value = ProcessInfo.processInfo.environment["SINODAL_OPEN_SEARCH"], !value.isEmpty else {
            return nil
        }
        return value
    }()

    /// `SINODAL_SHOW_WHATS_NEW=1` — forces the «Что нового» splash sheet
    /// (`WhatsNewView`) to show at launch, regardless of the stored
    /// `whatsNewShownVersion` — see `ContentView.swift`.
    static let showWhatsNew: Bool = {
        ProcessInfo.processInfo.environment["SINODAL_SHOW_WHATS_NEW"] == "1"
    }()

    static let openVerse: (bookId: String, chapter: Int, verse: Int)? = {
        guard let raw = ProcessInfo.processInfo.environment["SINODAL_OPEN_VERSE"] else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 3, let chapter = Int(parts[1]), let verse = Int(parts[2]) else {
            #if DEBUG
            print("[DebugLaunchHooks] SINODAL_OPEN_VERSE must be '<book>:<chapter>:<verse>', got \(raw.debugDescription)")
            #endif
            return nil
        }
        let bookToken = String(parts[0])
        let bookId = BookAliasMapper.bookId(for: bookToken) ?? bookToken
        return (bookId, chapter, verse)
    }()

    // MARK: - Package D: Псалтирь по кафизмам (akathist_psalter_design.md §6/§7)
    //
    //  * `SINODAL_OPEN_KATHISMA=<1...20>` — opens the reader directly at that
    //    kathisma (over the Synodal text), e.g. `SINODAL_OPEN_KATHISMA=13`.
    //  * `SINODAL_OPEN_KATHISMA=<1...20>:<1...3>` — same, plus scrolls to the
    //    given «Слава» (e.g. `SINODAL_OPEN_KATHISMA=13:2`) — lets a screenshot
    //    verify the scroll-to-«Слава» path without a touch/scroll harness.
    //  * `SINODAL_OPEN_PSALTER=1` — switches to the «Библия» tab and opens
    //    the «Псалтирь по кафизмам» sheet (`PsalterSheet`).
    //  * `SINODAL_OPEN_KATHISMA_SHEET=cs|prayers` — with `SINODAL_OPEN_KATHISMA`
    //    set, also presents the reader's «ЦС» or «Молитвы по кафизме» sheet on
    //    appear — the divider row's own `SlavaPrayersSheet` needs a tap to
    //    reach and has no such hook (it's a fixed, route-independent text).

    static let openKathismaNumber: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["SINODAL_OPEN_KATHISMA"] else { return nil }
        let numberToken = raw.split(separator: ":").first.map(String.init) ?? raw
        guard let number = Int(numberToken), (1...20).contains(number) else { return nil }
        return number
    }()

    static let openKathismaSlava: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["SINODAL_OPEN_KATHISMA"] else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let slava = Int(parts[1]), (1...3).contains(slava) else { return nil }
        return slava
    }()

    static let openPsalter: Bool = {
        ProcessInfo.processInfo.environment["SINODAL_OPEN_PSALTER"] == "1"
    }()

    enum KathismaSheet: String {
        case slavonic = "cs"
        case prayers
    }

    static let openKathismaSheet: KathismaSheet? = {
        guard let raw = ProcessInfo.processInfo.environment["SINODAL_OPEN_KATHISMA_SHEET"] else { return nil }
        return KathismaSheet(rawValue: raw)
    }()

    // MARK: - Package C: «Мои чтения» (akathist_psalter_design.md §5/§7)
    //
    //  * `SINODAL_OPEN_PRAYER=<slug>` — switches to the «Молитвы» tab and
    //    opens `PrayerDetailView(slug:)` for `<slug>` directly (see
    //    `PrayersView.task`).
    //  * `SINODAL_OPEN_PLAN_SETUP=<slug>` — same navigation as
    //    `SINODAL_OPEN_PRAYER`, plus `PrayerDetailView` presents
    //    `ReadingPlanSetupSheet` on appear once the prayer with this slug
    //    loads.
    //  * `SINODAL_DEMO_PLAN=<slug>` — starts a 40-day `dailyPrayer` plan for
    //    `<slug>` with 11 days already marked (dates back-filled), so the
    //    ring shows 11/40 without hand-tapping through eleven days — see
    //    `applyDemoPlanIfNeeded()`, called from `ContentView.onAppear`.
    //  * `SINODAL_OPEN_PRAYERS_ROOT=1` — switches to the «Молитвы» tab
    //    without pushing any prayer (root screen, for screenshotting
    //    «Мои чтения» — usually paired with `SINODAL_DEMO_PLAN`).

    static let openPrayersRoot: Bool = {
        ProcessInfo.processInfo.environment["SINODAL_OPEN_PRAYERS_ROOT"] == "1"
    }()

    /// `SINODAL_OPEN_AKAFISTY_LIST=1` — switches to the «Молитвы» tab and
    /// pushes the «Акафисты» category list (`PrayerListView`), for
    /// screenshot-verifying the plan hint caption under the header (see
    /// `PrayerListView.planHint(forCategorySlug:)`).
    static let openAkafistyList: Bool = {
        ProcessInfo.processInfo.environment["SINODAL_OPEN_AKAFISTY_LIST"] == "1"
    }()

    static let openPrayerSlug: String? = {
        guard let value = ProcessInfo.processInfo.environment["SINODAL_OPEN_PRAYER"], !value.isEmpty else {
            return nil
        }
        return value
    }()

    static let openPlanSetupSlug: String? = {
        guard let value = ProcessInfo.processInfo.environment["SINODAL_OPEN_PLAN_SETUP"], !value.isEmpty else {
            return nil
        }
        return value
    }()

    /// `SINODAL_OPEN_CONTENTS=<slug>` — same navigation as `SINODAL_OPEN_PRAYER`,
    /// plus `PrayerDetailView` presents `PrayerContentsSheet` on appear once the
    /// prayer with this slug loads (only if it actually has ≥8 rubric paragraphs —
    /// same threshold as the toolbar button).
    static let openContentsSlug: String? = {
        guard let value = ProcessInfo.processInfo.environment["SINODAL_OPEN_CONTENTS"], !value.isEmpty else {
            return nil
        }
        return value
    }()

    /// `SINODAL_OPEN_TYPOGRAPHY=<slug>` — same navigation as `SINODAL_OPEN_PRAYER`,
    /// plus `PrayerDetailView` presents `ReaderTypographySheet` (the «Текст»
    /// reading-settings sheet, opened via the toolbar's `textformat.size`
    /// button) on appear once the prayer with this slug loads — used to
    /// screenshot-verify the sheet's title colour without a tap harness.
    static let openTypographySlug: String? = {
        guard let value = ProcessInfo.processInfo.environment["SINODAL_OPEN_TYPOGRAPHY"], !value.isEmpty else {
            return nil
        }
        return value
    }()

    /// `SINODAL_OPEN_BOOKMARKS=1` — switches to the «Молитвы» tab, seeds a
    /// couple of bookmarks (if there are none yet) so the root screen's
    /// «Закладки» `PrayerRowsCard` section is visible without a tap harness,
    /// then leaves navigation on the root screen. See `seedBookmarksIfNeeded()`.
    static let openBookmarks: Bool = {
        ProcessInfo.processInfo.environment["SINODAL_OPEN_BOOKMARKS"] == "1"
    }()

    @MainActor
    static func seedBookmarksIfNeeded() {
        guard openBookmarks else { return }
        let store = PrayersUserDataStore.shared
        guard store.bookmarkSlugs.isEmpty else { return }
        for slug in ["communion.nachalo-obychnoe", "thanksgiving.blagodarstvennaya-molitva-1-ya"] {
            store.toggleBookmark(slug)
        }
    }

    static let demoPlanSlug: String? = {
        guard let value = ProcessInfo.processInfo.environment["SINODAL_DEMO_PLAN"], !value.isEmpty else {
            return nil
        }
        return value
    }()

    /// Starts a 40-day `dailyPrayer` plan for `demoPlanSlug` and backfills 11
    /// days of marks (dates `-11…-1` from today — today itself deliberately
    /// left unmarked, so both the ring at 11/40 AND the «Прочитано сегодня»
    /// button are visible in the same screenshot). Skips creating a duplicate
    /// plan if one already exists for this slug (repeated debug launches on
    /// the same simulator install shouldn't pile up plans).
    @MainActor
    static func applyDemoPlanIfNeeded() {
        guard let slug = demoPlanSlug else { return }
        let store = ReadingPlansStore.shared
        guard store.plan(forTarget: slug) == nil else { return }
        let uuid = store.start(kind: .dailyPrayer(slug: slug), totalUnits: 40,
                                endDateRule: nil, endDate: nil, reminderTime: nil)
        let calendar = Calendar.current
        for offset in stride(from: 11, through: 1, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            store.markDone(planUUID: uuid, on: day)
        }
    }
}
#endif
