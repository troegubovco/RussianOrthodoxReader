import SwiftUI
import Combine

enum AppFontFamily: String, CaseIterable, Identifiable {
    case cormorant = "cormorant"
    case serif = "serif"
    case system = "system"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cormorant:
            return "Корморант"
        case .serif:
            return "С засечками"
        case .system:
            return "Без засечек"
        }
    }
}

class AppState: ObservableObject {
    static let minimumFontSize: Double = 25
    static let defaultFontSize: Double = 33
    static let maximumFontSize: Double = 52

    @Published var selectedTab: Tab = .today
    @Published var calendarResetTrigger: Int = 0
    @Published var hasPrayedToday: Bool = false
    @Published var showPrayerOverlay: Bool = false
    @Published var fontSize: Double {
        didSet {
            let clamped = Self.clampFontSize(fontSize)
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            UserDefaults.standard.set(fontSize, forKey: Keys.fontSize)
        }
    }
    @Published var fontFamily: AppFontFamily {
        didSet {
            UserDefaults.standard.set(fontFamily.rawValue, forKey: Keys.fontFamily)
            AppFont.setFamily(fontFamily)
        }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
        }
    }
    @Published var notificationTime: String {
        didSet {
            UserDefaults.standard.set(notificationTime, forKey: Keys.notificationTime)
        }
    }
    
    enum Tab: String, CaseIterable {
        case today = "Сегодня"
        case bible = "Библия"
        case calendar = "Календарь"
        case settings = "Настройки"
        
        var icon: String {
            switch self {
            case .today: return "sun.max"
            case .bible: return "book"
            case .calendar: return "calendar"
            case .settings: return "gearshape"
            }
        }
    }
    
    // MARK: - Prayer Logic
    
    private let prayerDateKey = "lastPrayerDate"
    
    private enum Keys {
        static let fontSize = "fontSize"
        static let fontFamily = "fontFamily"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationTime = "notificationTime"
    }
    
    init() {
        let defaults = UserDefaults.standard
        let savedSize = defaults.object(forKey: Keys.fontSize) as? Double
        self.fontSize = Self.clampFontSize(savedSize ?? Self.defaultFontSize)
        
        let savedFamily = defaults.string(forKey: Keys.fontFamily)
        self.fontFamily = AppFontFamily(rawValue: savedFamily ?? AppFontFamily.cormorant.rawValue) ?? .cormorant
        
        if defaults.object(forKey: Keys.notificationsEnabled) != nil {
            self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        } else {
            self.notificationsEnabled = true
        }
        
        self.notificationTime = defaults.string(forKey: Keys.notificationTime) ?? "20:00"
        
        checkPrayerStatus()
        
        // Initialize font family in AppFont to avoid repeated UserDefaults reads
        AppFont.setFamily(self.fontFamily)
    }

    static func clampFontSize(_ value: Double) -> Double {
        min(max(value, minimumFontSize), maximumFontSize)
    }
    
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
    /// Returns `true` if reading can proceed (prayer already done),
    /// returns `false` and shows overlay if prayer is needed.
    func requestReading() -> Bool {
        if hasPrayedToday {
            return true
        } else {
            showPrayerOverlay = true
            return false
        }
    }
}
