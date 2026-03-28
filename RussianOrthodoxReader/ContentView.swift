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
                    }
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
        }
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
                    }
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
                    onResume: resumeAction
                )
                .opacity(appState.selectedTab == .bible ? 1 : 0)
                .zIndex(appState.selectedTab == .bible ? 1 : 0)
            }

            if loadedTabs.contains(.calendar) {
                CalendarView()
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
            BibleView(onSelectChapter: openReading, onResume: resumeAction)
        case .calendar:
            CalendarView()
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
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityHint(appState.selectedTab == tab ? "Нажмите дважды для возврата" : "")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
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
        case .today, .settings:
            break
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
