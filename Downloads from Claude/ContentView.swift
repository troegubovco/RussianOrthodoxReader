import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var calendarService = AzbykaCalendarService()
    
    var body: some View {
        ZStack {
            // MARK: - All tabs rendered simultaneously, visibility toggled
            // This is the key change: instead of conditionally creating/destroying
            // views with `if/else`, we keep all tabs alive and toggle opacity/interaction.
            // This preserves scroll position, navigation stacks, and selections.
            
            TabContent(tab: .today) {
                TodayView()
                    .environmentObject(calendarService)
            }
            
            TabContent(tab: .bible) {
                BibleView()
            }
            
            TabContent(tab: .calendar) {
                CalendarView()
                    .environmentObject(calendarService)
            }
            
            TabContent(tab: .settings) {
                SettingsView()
                    .environmentObject(calendarService)
            }
            
            // MARK: - Prayer Overlay
            if appState.showPrayerOverlay {
                PrayerOverlay(onComplete: {
                    appState.markPrayerRead()
                })
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(10)
            }
        }
        .safeAreaInset(edge: .bottom) {
            TabBarView()
        }
        .task {
            await calendarService.fetchToday()
        }
    }
    
    /// Wrapper that keeps a tab's content alive but hidden when not selected.
    /// Uses opacity + allowsHitTesting instead of conditional rendering.
    @ViewBuilder
    private func TabContent<Content: View>(
        tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .environmentObject(appState.stateFor(tab))
            .opacity(appState.selectedTab == tab ? 1 : 0)
            .allowsHitTesting(appState.selectedTab == tab)
            // Keep the view in the hierarchy but non-interactive when hidden
            .accessibilityHidden(appState.selectedTab != tab)
    }
}

// MARK: - Tab Bar with Double-Tap Detection

struct TabBarView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack {
            ForEach(AppTab.allCases) { tab in
                TabBarButton(tab: tab)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 28)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color(hex: "EDE8E0"))
                        .frame(height: 0.5)
                }
        )
    }
}

struct TabBarButton: View {
    let tab: AppTab
    @EnvironmentObject var appState: AppState
    
    private var isSelected: Bool {
        appState.selectedTab == tab
    }
    
    var body: some View {
        Button {
            appState.handleTabTap(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 22))
                Text(tab.rawValue)
                    .font(.custom("CormorantGaramond-Regular", size: 11))
            }
            .foregroundColor(isSelected ? Color(hex: "8B6914") : Color(hex: "9E9484"))
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Нажмите дважды для возврата на главный экран вкладки" : "")
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
}
