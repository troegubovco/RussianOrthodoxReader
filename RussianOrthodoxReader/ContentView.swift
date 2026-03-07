//
//  ContentView.swift
//  RussianOrthodoxReader
//
//  Created by Andrey Troegubov on 2/25/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var readerRoute: ReaderRoute? = nil
    @State private var pendingRoute: ReaderRoute? = nil
    @State private var loadedTabs: Set<AppState.Tab> = [.today] // Start with today loaded

    private let theme = OrthodoxColors.fallback

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            if let route = readerRoute {
                ReaderView(route: route) {
                    readerRoute = nil
                }
            } else {
                ZStack {
                    if loadedTabs.contains(.today) {
                        TodayView(onOpenReading: openReading)
                            .opacity(appState.selectedTab == .today ? 1 : 0)
                            .zIndex(appState.selectedTab == .today ? 1 : 0)
                    }

                    if loadedTabs.contains(.bible) {
                        BibleView(onSelectChapter: openReading)
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
                    // Load the tab if it hasn't been loaded yet
                    if !loadedTabs.contains(newTab) {
                        loadedTabs.insert(newTab)
                    }
                }
            }

            if appState.showPrayerOverlay {
                PrayerOverlay {
                    appState.markPrayerRead()
                    if let pending = pendingRoute {
                        readerRoute = pending
                        pendingRoute = nil
                    }
                }
                .zIndex(100)
            }
        }
        .environment(\.userFontSize, CGFloat(appState.fontSize))
    }

    private func openReading(_ route: ReaderRoute) {
        if appState.requestReading() {
            readerRoute = route
        } else {
            pendingRoute = route
        }
    }
}

struct TabBarView: View {
    @EnvironmentObject var appState: AppState
    private let theme = OrthodoxColors.fallback

    var body: some View {
        HStack {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                Button {
                    if appState.selectedTab == tab && tab == .calendar {
                        appState.calendarResetTrigger += 1
                    }
                    appState.selectedTab = tab
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
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
