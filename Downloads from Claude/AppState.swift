import SwiftUI

// MARK: - Tab Definition

enum AppTab: String, CaseIterable, Identifiable {
    case today = "Сегодня"
    case bible = "Библия"
    case calendar = "Календарь"
    case settings = "Настройки"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .bible: return "book"
        case .calendar: return "calendar"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Per-Tab Navigation State

/// Holds the full navigation state for a single tab so it survives tab switches.
class TabNavigationState: ObservableObject {
    let tab: AppTab
    
    /// NavigationPath for programmatic push/pop
    @Published var navigationPath = NavigationPath()
    
    /// Scroll position identifier (for ScrollViewReader)
    @Published var scrollAnchorID: String?
    
    /// Tab-specific selections
    @Published var selectedBibleTestament: BibleTestament = .new
    @Published var selectedBibleBook: String?
    @Published var selectedBibleChapter: String?
    
    @Published var calendarYear: Int
    @Published var calendarMonth: Int  // 1-indexed
    @Published var selectedCalendarDay: Int?
    
    /// Whether the user is in a deep (non-root) view
    var isAtRoot: Bool {
        navigationPath.isEmpty
    }
    
    init(tab: AppTab) {
        self.tab = tab
        let now = Date()
        let cal = Calendar.current
        self.calendarYear = cal.component(.year, from: now)
        self.calendarMonth = cal.component(.month, from: now)
    }
    
    /// Reset to root state (called on double-tap)
    func resetToRoot() {
        withAnimation(.easeInOut(duration: 0.2)) {
            navigationPath = NavigationPath()
            scrollAnchorID = nil
            
            switch tab {
            case .bible:
                selectedBibleBook = nil
                selectedBibleChapter = nil
            case .calendar:
                let now = Date()
                let cal = Calendar.current
                calendarYear = cal.component(.year, from: now)
                calendarMonth = cal.component(.month, from: now)
                selectedCalendarDay = nil
            default:
                break
            }
        }
    }
}

enum BibleTestament: String, CaseIterable {
    case old = "Ветхий Завет"
    case new = "Новый Завет"
}

// MARK: - App State

class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .today
    @Published var previousTab: AppTab? = nil
    @Published var hasPrayedToday: Bool = false
    @Published var showPrayerOverlay: Bool = false
    
    @AppStorage("fontSize") var fontSize: Double = 19
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    @AppStorage("notificationTime") var notificationTime: String = "20:00"
    
    /// Per-tab navigation states — these persist across tab switches
    let tabStates: [AppTab: TabNavigationState]
    
    /// Timestamp of last tap on each tab (for double-tap detection)
    private var lastTabTapTime: [AppTab: Date] = [:]
    private let doubleTapThreshold: TimeInterval = 0.35
    
    // MARK: - Prayer Logic
    
    private let prayerDateKey = "lastPrayerDate"
    
    init() {
        // Initialize per-tab states
        var states: [AppTab: TabNavigationState] = [:]
        for tab in AppTab.allCases {
            states[tab] = TabNavigationState(tab: tab)
        }
        self.tabStates = states
        
        checkPrayerStatus()
    }
    
    /// Get the navigation state for a specific tab
    func stateFor(_ tab: AppTab) -> TabNavigationState {
        tabStates[tab]!
    }
    
    // MARK: - Tab Switching with State Preservation
    
    /// Call this when a tab bar button is tapped.
    /// - Single tap on different tab: switch tabs (previous tab state is preserved automatically)
    /// - Single tap on current tab: no-op
    /// - Double tap on current tab: reset to root
    func handleTabTap(_ tab: AppTab) {
        let now = Date()
        
        if tab == selectedTab {
            // Same tab tapped — check for double-tap
            if let lastTap = lastTabTapTime[tab],
               now.timeIntervalSince(lastTap) < doubleTapThreshold {
                // Double tap detected → reset to root
                stateFor(tab).resetToRoot()
                lastTabTapTime[tab] = nil  // Reset so triple-tap doesn't re-trigger
            } else {
                lastTabTapTime[tab] = now
            }
        } else {
            // Different tab — switch
            // previousTab state is already preserved in tabStates dictionary
            withAnimation(.easeInOut(duration: 0.15)) {
                previousTab = selectedTab
                selectedTab = tab
            }
            lastTabTapTime[tab] = now
        }
    }
    
    // MARK: - Prayer Logic
    
    func checkPrayerStatus() {
        let today = Calendar.current.startOfDay(for: Date())
        if let lastDate = UserDefaults.standard.object(forKey: prayerDateKey) as? Date {
            hasPrayedToday = Calendar.current.isDate(lastDate, inSameDayAs: today)
        } else {
            hasPrayedToday = false
        }
    }
    
    func markPrayerRead() {
        let today = Calendar.current.startOfDay(for: Date())
        UserDefaults.standard.set(today, forKey: prayerDateKey)
        withAnimation(.easeOut(duration: 0.3)) {
            hasPrayedToday = true
            showPrayerOverlay = false
        }
    }
    
    /// Call this before opening any Scripture reading.
    /// Returns `true` if reading can proceed (prayer already done).
    /// Returns `false` and shows overlay if prayer is needed.
    func requestReading() -> Bool {
        checkPrayerStatus()
        if hasPrayedToday {
            return true
        } else {
            showPrayerOverlay = true
            return false
        }
    }
}
