//
//  ContentView.swift
//  RussianOrthodoxReader
//
//  Created by Andrey Troegubov on 2/25/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var readerRoute: ReaderRoute? = nil
    @State private var pendingRoute: ReaderRoute? = nil
    @State private var loadedTabs: Set<AppState.Tab> = [.today]
    /// Controls whether the reader layer is visible. The reader view stays in the
    /// hierarchy (to preserve scroll position) whenever `readerRoute != nil`.
    @State private var isReadingMode: Bool = false
    @State private var activeReaderChapterRoute: ReaderRoute? = nil
    /// Verse to scroll to and highlight on the next reader open — set from a
    /// Bible search result tap (`BibleView.onSelectVerse`). Cleared once the
    /// reader reports that chapter as visible. See search_design.md §4.5.
    @State private var readerInitialVerse: Int? = nil
    /// «Слава» (1...3) to scroll to on the next reader open when the route is
    /// `.kathisma` — set from a `PsalterSheet` «Слава» sub-row tap
    /// (`BibleView.onSelectKathisma`). See akathist_psalter_design.md §6.
    @State private var readerInitialSlava: Int? = nil
    #if DEBUG
    /// Set from the `SINODAL_OPEN_SEARCH` DEBUG launch hook (DebugLaunchHooks.swift).
    @State private var debugSearchQuery: String? = nil
    #endif

    /// Версия, для которой пользователь уже видел лист «Что нового» —
    /// пустая строка на свежей установке (не показываем, только запоминаем).
    @AppStorage("whatsNewShownVersion") private var whatsNewShownVersion = ""
    @State private var showWhatsNew = false

    private let theme = OrthodoxColors.fallback

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            // Tab layer — always rendered; hidden while reading to preserve tab state.
            #if os(macOS)
            tabLayer
            #else
            tabLayer
                .opacity(isReadingMode ? 0 : 1)
                .allowsHitTesting(!isReadingMode)

            // Reader layer — kept in hierarchy when route exists so that scroll
            // position is preserved across tab switches.
            if let route = readerRoute {
                ReaderView(
                    route: route,
                    onBack: { currentRoute in
                        persistCurrentReaderRoute(currentRoute)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isReadingMode = false
                        }
                    },
                    onSwitchTab: { tab, currentRoute in
                        persistCurrentReaderRoute(currentRoute)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isReadingMode = false
                            appState.selectedTab = tab
                        }
                    },
                    onVisibleRouteChange: { route in
                        activeReaderChapterRoute = route
                    },
                    onOpenVerse: openReadingAtVerse,
                    initialVerse: readerInitialVerse,
                    initialSlava: readerInitialSlava
                )
                .opacity(isReadingMode ? 1 : 0)
                .allowsHitTesting(isReadingMode)
            }
            #endif

            if appState.showPrayerOverlay {
                PrayerOverlay {
                    appState.markPrayerRead()
                    if let pending = pendingRoute {
                        persistCurrentReaderRoute(pending)
                        readerRoute = pending
                        pendingRoute = nil
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isReadingMode = true
                        }
                    }
                }
                .zIndex(100)
            }
        }
        .environment(\.userFontSize, CGFloat(appState.fontSize))
        .onAppear {
            // Restore reading position from the previous session.
            if readerRoute == nil, let saved = appState.lastReadingRoute {
                readerRoute = saved
                activeReaderChapterRoute = saved
            }
            #if DEBUG
            BibleReferenceQuery.runSelfCheck()
            if let query = DebugLaunchHooks.openSearchQuery {
                appState.selectedTab = .bible
                debugSearchQuery = query
            }
            if let target = DebugLaunchHooks.openVerse {
                appState.selectedTab = .bible
                // Skip the "prayer before reading" gate for this hook: on a
                // fresh install `requestReading()` would show that overlay
                // instead of opening the reader, and its pending-route path
                // doesn't carry a verse target (see `openReadingAtVerse`), so
                // the verse would silently get lost.
                appState.hasPrayedToday = true
                openReadingAtVerse(bookId: target.bookId, chapter: target.chapter, verse: target.verse)
            }
            // Package D: Псалтирь по кафизмам — see DebugLaunchHooks.swift.
            if DebugLaunchHooks.openPsalter {
                appState.selectedTab = .bible
            }
            if let number = DebugLaunchHooks.openKathismaNumber {
                appState.selectedTab = .bible
                // Skip the prayer gate for this hook, same reasoning as
                // `SINODAL_OPEN_VERSE` above.
                appState.hasPrayedToday = true
                openKathisma(number: number, initialSlava: DebugLaunchHooks.openKathismaSlava)
            }
            // Package C: «Мои чтения» — see DebugLaunchHooks.swift.
            DebugLaunchHooks.applyDemoPlanIfNeeded()
            if DebugLaunchHooks.openPrayerSlug != nil
                || DebugLaunchHooks.openPlanSetupSlug != nil
                || DebugLaunchHooks.openContentsSlug != nil
                || DebugLaunchHooks.openTypographySlug != nil
                || DebugLaunchHooks.openPrayersRoot
                || DebugLaunchHooks.openAkafistyList
                || DebugLaunchHooks.openBookmarks {
                appState.selectedTab = .prayers
            }
            DebugLaunchHooks.seedBookmarksIfNeeded()
            #endif
            checkWhatsNew()
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView()
                .environment(\.userFontSize, CGFloat(appState.fontSize))
                .onDisappear {
                    whatsNewShownVersion = currentAppVersion
                }
        }
        #if DEBUG
        .sheet(isPresented: Binding(
            get: { debugSearchQuery != nil },
            set: { if !$0 { debugSearchQuery = nil } }
        )) {
            BibleSearchView(initialQuery: debugSearchQuery ?? "", onSelectVerse: openReadingAtVerse)
        }
        #endif
        .onChange(of: appState.lastReadingRoute) { _, newRoute in
            // Pick up cloud-synced reading position when not actively reading.
            if let newRoute, case .chapter = newRoute {
                activeReaderChapterRoute = newRoute
            }
            if !isReadingMode, let newRoute, newRoute != readerRoute {
                DispatchQueue.main.async {
                    readerRoute = newRoute
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                persistCurrentReaderRoute()
            }
        }
        .onChange(of: appState.showPrayerOverlay) { _, isShowing in
            // Не спорим с плашкой «Помолитесь перед чтением» за экран —
            // откладываем показ «Что нового» до её закрытия.
            if !isShowing {
                checkWhatsNew()
            }
        }
    }

    /// Текущая версия приложения (`CFBundleShortVersionString`), например «1.5».
    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Показывает лист «Что нового», если версия приложения изменилась с
    /// прошлого показа. На свежей установке (`whatsNewShownVersion` пуст)
    /// ничего не показывает — только запоминает текущую версию, чтобы лист
    /// появился лишь после следующего обновления.
    private func checkWhatsNew() {
        #if DEBUG
        if DebugLaunchHooks.showWhatsNew {
            showWhatsNew = true
            return
        }
        #endif
        guard !ScreenshotMode.isActive else { return }
        guard !appState.showPrayerOverlay else { return }
        let current = currentAppVersion
        guard !current.isEmpty else { return }
        if whatsNewShownVersion.isEmpty {
            whatsNewShownVersion = current
            return
        }
        if whatsNewShownVersion != current {
            showWhatsNew = true
        }
    }

    /// Non-nil when the reader is hidden but a route is loaded — shown as a banner in BibleView.
    private var resumeAction: (() -> Void)? {
        guard readerRoute != nil, !isReadingMode else { return nil }
        return { self.resumeReading() }
    }

    #if os(macOS)
    /// Deferred binding so that NavigationSplitView's selection change is applied
    /// on the next run-loop pass, avoiding "Publishing changes from within view
    /// updates" when SwiftUI mutates the selection during a layout pass.
    private var deferredTabSelection: Binding<AppState.Tab?> {
        Binding<AppState.Tab?>(
            get: { appState.selectedTab },
            set: { newTab in
                guard let tab = newTab else { return }
                DispatchQueue.main.async {
                    appState.selectedTab = tab
                }
            }
        )
    }
    #endif

    // MARK: - Tab layer

    @ViewBuilder
    private var tabLayer: some View {
        #if os(macOS)
        NavigationSplitView {
            List(AppState.Tab.allCases, id: \.self, selection: deferredTabSelection) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            if isReadingMode, let route = readerRoute {
                ReaderView(
                    route: route,
                    onBack: { currentRoute in
                        persistCurrentReaderRoute(currentRoute)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isReadingMode = false
                        }
                    },
                    onVisibleRouteChange: { route in
                        activeReaderChapterRoute = route
                    },
                    onOpenVerse: openReadingAtVerse,
                    initialVerse: readerInitialVerse,
                    initialSlava: readerInitialSlava
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
            } else {
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
            }
        }
        .navigationTitle("")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #else
        ZStack {
            if loadedTabs.contains(.today) {
                TodayView(onOpenReading: openReading)
                    .opacity(appState.selectedTab == .today ? 1 : 0)
                    .zIndex(appState.selectedTab == .today ? 1 : 0)
            }

            if loadedTabs.contains(.bible) {
                BibleView(
                    onSelectChapter: openReading,
                    onResume: resumeAction,
                    onSelectVerse: openReadingAtVerse,
                    onSelectKathisma: openKathisma
                )
                .opacity(appState.selectedTab == .bible ? 1 : 0)
                .zIndex(appState.selectedTab == .bible ? 1 : 0)
            }

            if loadedTabs.contains(.prayers) {
                PrayersView()
                    .opacity(appState.selectedTab == .prayers ? 1 : 0)
                    .zIndex(appState.selectedTab == .prayers ? 1 : 0)
            }

            if loadedTabs.contains(.calendar) {
                CalendarView(onOpenReading: openReading)
                    .opacity(appState.selectedTab == .calendar ? 1 : 0)
                    .zIndex(appState.selectedTab == .calendar ? 1 : 0)
            }

            if loadedTabs.contains(.settings) {
                SettingsView()
                    .opacity(appState.selectedTab == .settings ? 1 : 0)
                    .zIndex(appState.selectedTab == .settings ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBarView()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeInOut(duration: 0.25), value: appState.selectedTab)
        .onChange(of: appState.selectedTab) { _, newTab in
            if !loadedTabs.contains(newTab) {
                loadedTabs.insert(newTab)
            }
        }
        #endif
    }

    @ViewBuilder
    private var tabContent: some View {
        switch appState.selectedTab {
        case .today:
            TodayView(onOpenReading: openReading)
        case .bible:
            BibleView(onSelectChapter: openReading, onResume: resumeAction, onSelectVerse: openReadingAtVerse, onSelectKathisma: openKathisma)
        case .prayers:
            PrayersView()
        case .calendar:
            CalendarView(onOpenReading: openReading)
        case .settings:
            SettingsView()
        }
    }

    // MARK: - Actions

    private func resumeReading() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isReadingMode = true
        }
    }

    private func openReading(_ route: ReaderRoute) {
        // A plain chapter open should never carry over a verse target left
        // behind by a previous `openReadingAtVerse` call (e.g. Ин 3:16 via
        // search, then browsing straight to another chapter).
        readerInitialVerse = nil
        readerInitialSlava = nil
        if appState.requestReading() {
            persistCurrentReaderRoute(route)
            readerRoute = route
            withAnimation(.easeInOut(duration: 0.2)) {
                isReadingMode = true
            }
        } else {
            pendingRoute = route
        }
    }

    /// Opens the reader at a specific verse — used by a Bible search result
    /// tap (`BibleView.onSelectVerse`, wired from `BibleSearchView`). A
    /// separate function rather than a defaulted `verse:` parameter on
    /// `openReading` because the latter is passed by reference as a bare
    /// `(ReaderRoute) -> Void` closure in several places, and a defaulted
    /// parameter doesn't survive that (Swift keeps the full signature).
    private func openReadingAtVerse(bookId: String, chapter: Int, verse: Int) {
        let route = ReaderRoute.chapter(bookId: bookId, chapter: chapter)
        readerInitialSlava = nil
        if appState.requestReading() {
            persistCurrentReaderRoute(route)
            readerRoute = route
            readerInitialVerse = verse
            withAnimation(.easeInOut(duration: 0.2)) {
                isReadingMode = true
            }
        } else {
            // The prayer-gate pending-route path doesn't carry a verse target;
            // the chapter still opens correctly once the prayer is read.
            pendingRoute = route
        }
    }

    /// Opens the reader at a kathisma of the Псалтирь по кафизмам, optionally
    /// scrolled to one of its three «Славы» — used by `BibleView.onSelectKathisma`
    /// (`PsalterSheet`'s kathisma/«Слава» rows) and the `SINODAL_OPEN_KATHISMA`
    /// DEBUG launch hook. `.kathisma` routes aren't `.chapter`, so — like
    /// `.references` — they fall outside `persistCurrentReaderRoute`'s
    /// "продолжить чтение" persistence; see akathist_psalter_design.md §6.1.
    private func openKathisma(number: Int, initialSlava: Int?) {
        readerInitialVerse = nil
        let route = ReaderRoute.kathisma(number: number)
        if appState.requestReading() {
            readerRoute = route
            readerInitialSlava = initialSlava
            withAnimation(.easeInOut(duration: 0.2)) {
                isReadingMode = true
            }
        } else {
            pendingRoute = route
        }
    }

    private func persistCurrentReaderRoute(_ candidate: ReaderRoute? = nil) {
        guard let route = resolvedChapterRoute(candidate) else { return }
        activeReaderChapterRoute = route
        appState.recordLocalReadingRoute(route)
        appState.syncReadingRouteToCloud(route: route)
    }

    private func resolvedChapterRoute(_ candidate: ReaderRoute? = nil) -> ReaderRoute? {
        if let candidate {
            guard case .chapter = candidate else { return nil }
            return candidate
        }
        if let activeReaderChapterRoute, case .chapter = activeReaderChapterRoute {
            return activeReaderChapterRoute
        }
        if let readerRoute, case .chapter = readerRoute {
            return readerRoute
        }
        return nil
    }
}

struct TabBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var lastTapTime: [AppState.Tab: Date] = [:]
    private let doubleTapThreshold: TimeInterval = 0.35
    private let theme = OrthodoxColors.fallback

    var body: some View {
        HStack {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                Button {
                    handleTap(tab)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 22))
                        Text(tab.rawValue)
                            .font(AppFont.regular(11))
                    }
                    .foregroundColor(appState.selectedTab == tab ? theme.accent : theme.muted)
                    .animation(.easeInOut(duration: 0.2), value: appState.selectedTab)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityHint(appState.selectedTab == tab ? "Нажмите дважды для возврата" : "")
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(
            theme.background.opacity(0.95)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 0.5)
        }
    }

    private func handleTap(_ tab: AppState.Tab) {
        let now = Date()
        if appState.selectedTab == tab {
            // Same tab — check for double-tap
            if let lastTap = lastTapTime[tab],
               now.timeIntervalSince(lastTap) < doubleTapThreshold {
                handleDoubleTap(tab)
                lastTapTime[tab] = nil
            } else {
                lastTapTime[tab] = now
            }
        } else {
            appState.selectedTab = tab
            lastTapTime[tab] = nil
        }
    }

    private func handleDoubleTap(_ tab: AppState.Tab) {
        switch tab {
        case .calendar:
            appState.calendarResetTrigger += 1
        case .bible:
            appState.bibleResetTrigger += 1
        case .prayers:
            appState.prayersResetTrigger += 1
        case .today, .settings:
            break
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
