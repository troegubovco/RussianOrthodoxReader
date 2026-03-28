import SwiftUI
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "OG.RussianOrthodoxReader", category: "AppState")

enum AppFontFamily: String, CaseIterable, Identifiable {
    case cormorant = "cormorant"
    case serif = "serif"
    case system = "system"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cormorant: return "Корморант"
        case .serif:     return "С засечками"
        case .system:    return "Без засечек"
        }
    }
}

@MainActor
class AppState: ObservableObject {
    static let minimumFontSize: Double = 25
    static let defaultFontSize: Double = 33
    static let maximumFontSize: Double = 52

    @Published var selectedTab: Tab = .today
    @Published var calendarResetTrigger: Int = 0
    @Published var bibleResetTrigger: Int = 0
    @Published var hasPrayedToday: Bool = false
    @Published var showPrayerOverlay: Bool = false

    /// Prevents duplicate refreshFromCloud calls (e.g. .task + .onChange both fire at launch).
    private var hasRefreshedFromCloud = false
    private var hasConfiguredReadingSync = false

    @Published var fontSize: Double {
        didSet {
            let clamped = Self.clampFontSize(fontSize)
            if clamped != fontSize { fontSize = clamped; return }
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
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled)
            Task {
                await ReadingStateSyncService.shared.setSyncEnabled(iCloudSyncEnabled)
            }
        }
    }

    /// Last chapter the user was reading — persisted locally and synced via CloudKit.
    /// Only `.chapter` routes are saved; `.references` are date-specific and ephemeral.
    @Published var lastReadingRoute: ReaderRoute? {
        didSet {
            // Persist locally only — CloudKit saves are triggered explicitly via
            // syncReadingRouteToCloud() at specific moments (enter, select, exit).
            if let route = lastReadingRoute, case .chapter = route,
               let data = try? JSONEncoder().encode(route) {
                UserDefaults.standard.set(data, forKey: Keys.lastReadingRoute)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastReadingRoute)
            }
        }
    }
    @Published private(set) var readingSyncPhase: ReadingSyncPhase
    @Published private(set) var readingSyncLastSyncDate: Date?
    @Published private(set) var readingSyncErrorDescription: String?

    /// Explicitly saves a reading route to CloudKit. Call this only at
    /// specific moments: entering a chapter, selecting a chapter, or exiting.
    func syncReadingRouteToCloud(route: ReaderRoute? = nil) {
        guard let route = route ?? lastReadingRoute, case .chapter = route else { return }
        Task {
            await ReadingStateSyncService.shared.updateLocalRoute(route)
        }
    }

    enum Tab: String, CaseIterable {
        case today    = "Сегодня"
        case bible    = "Библия"
        case calendar = "Календарь"
        case settings = "Настройки"

        var icon: String {
            switch self {
            case .today:    return "sun.max"
            case .bible:    return "book"
            case .calendar: return "calendar"
            case .settings: return "gearshape"
            }
        }
    }

    // MARK: - Prayer

    private let prayerDateKey = "lastPrayerDate"

    /// Formatter for the "yyyy-MM-dd" string stored in CloudKit.
    private static let prayerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale   = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private enum Keys {
        static let fontSize             = "fontSize"
        static let fontFamily           = "fontFamily"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationTime     = "notificationTime"
        static let lastReadingRoute     = "lastReadingRoute"
        static let iCloudSyncEnabled    = "iCloudSyncEnabled"
    }

    // MARK: - Init

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
        let syncEnabled: Bool
        if defaults.object(forKey: Keys.iCloudSyncEnabled) != nil {
            syncEnabled = defaults.bool(forKey: Keys.iCloudSyncEnabled)
        } else {
            syncEnabled = true
        }
        self.iCloudSyncEnabled = syncEnabled

        if let data = defaults.data(forKey: Keys.lastReadingRoute),
           let route = try? JSONDecoder().decode(ReaderRoute.self, from: data) {
            self.lastReadingRoute = route
        }
        self.readingSyncPhase = syncEnabled ? .starting : .disabled
        self.readingSyncLastSyncDate = nil
        self.readingSyncErrorDescription = nil

        checkPrayerStatus()
        AppFont.setFamily(self.fontFamily)
        // Cloud refresh is triggered from the App entry point via refreshFromCloud()
    }

    // MARK: - Helpers

    static func clampFontSize(_ value: Double) -> Double {
        min(max(value, minimumFontSize), maximumFontSize)
    }

    func recordLocalReadingRoute(_ route: ReaderRoute, updatedAt _: Date = Date()) {
        guard case .chapter = route else { return }
        lastReadingRoute = route
    }

    private func saveCloudSettings(_ settings: CloudSyncService.Settings) {
        #if canImport(UIKit) && !os(macOS)
        let backgroundTaskID = beginCloudSaveBackgroundTask()
        Task {
            defer {
                Task { @MainActor in
                    self.endCloudSaveBackgroundTask(backgroundTaskID)
                }
            }
            try? await CloudSyncService.shared.save(settings)
        }
        #else
        Task {
            try? await CloudSyncService.shared.save(settings)
        }
        #endif
    }

    #if canImport(UIKit) && !os(macOS)
    @MainActor
    private func beginCloudSaveBackgroundTask() -> UIBackgroundTaskIdentifier {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "CloudSyncSave") {
            UIApplication.shared.endBackgroundTask(identifier)
        }
        return identifier
    }

    @MainActor
    private func endCloudSaveBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
    #endif

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
        let dateString = Self.prayerDateFormatter.string(from: today)
        saveCloudSettings(.init(prayerReadDate: dateString))
        withAnimation(.easeOut(duration: 0.3)) {
            hasPrayedToday = true
            showPrayerOverlay = false
        }
    }

    /// Call this before opening any Scripture reading.
    /// Returns `true` if reading can proceed (prayer already done),
    /// returns `false` and shows the overlay if prayer is needed first.
    func requestReading() -> Bool {
        if hasPrayedToday {
            return true
        } else {
            showPrayerOverlay = true
            return false
        }
    }

    var readingSyncStatusTitle: String {
        switch readingSyncPhase {
        case .disabled:
            return "Синхронизация выключена"
        case .starting:
            return "Подключение к iCloud"
        case .syncing:
            return "Синхронизация"
        case .idle:
            return "Синхронизация активна"
        case .waitingForNetwork:
            return "Ожидание сети"
        case .accountUnavailable:
            return "iCloud недоступен"
        case .error:
            return "Ошибка синхронизации"
        }
    }

    var readingSyncStatusDetail: String {
        switch readingSyncPhase {
        case .disabled:
            return "Прогресс чтения остаётся только на этом устройстве."
        case .starting:
            return "Синхронизируется только место чтения: книга, глава, стих и время обновления."
        case .syncing:
            return "Используется ваша приватная база iCloud без публичного доступа."
        case .idle:
            if let readingSyncLastSyncDate {
                return "Последняя синхронизация: \(Self.syncStatusDateFormatter.string(from: readingSyncLastSyncDate))."
            }
            return "Изменения обычно приходят автоматически, когда устройства онлайн."
        case .waitingForNetwork:
            return "Изменения сохраняются локально и будут отправлены, когда сеть восстановится."
        case .accountUnavailable:
            return "Проверьте вход в iCloud и настройки CloudKit для приложения."
        case .error:
            return readingSyncErrorDescription ?? "Не удалось завершить синхронизацию."
        }
    }

    // MARK: - CloudKit Sync

    func refreshFromCloud(force: Bool = false) async {
        await configureReadingSyncIfNeeded()
        if force {
            await ReadingStateSyncService.shared.refreshNow()
        }

        // On first launch both .task and .onChange(of: scenePhase) fire;
        // skip the second call unless it's a genuine foreground transition.
        if hasRefreshedFromCloud && !force {
            logger.info("refreshFromCloud: skipping duplicate call")
            return
        }
        hasRefreshedFromCloud = true

        logger.info("refreshFromCloud: starting…")
        do {
            let settings = try await CloudSyncService.shared.load()
            logger.info("refreshFromCloud: loaded settings, applying…")
            applyCloudSettings(settings)
        } catch {
            logger.error("refreshFromCloud: failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func applyCloudSettings(_ settings: CloudSyncService.Settings) {
        // Mark prayer as done if cloud confirms it was completed today
        if let dateString = settings.prayerReadDate,
           let date = Self.prayerDateFormatter.date(from: dateString) {
            let today = Calendar.current.startOfDay(for: Date())
            if Calendar.current.isDate(date, inSameDayAs: today) && !hasPrayedToday {
                UserDefaults.standard.set(today, forKey: prayerDateKey)
                hasPrayedToday = true
            }
        }
    }

    private func configureReadingSyncIfNeeded() async {
        guard !hasConfiguredReadingSync else { return }
        hasConfiguredReadingSync = true

        ReadingStateSyncService.shared.setSnapshotHandler { [weak self] snapshot in
            Task { @MainActor in
                self?.applyReadingSyncSnapshot(snapshot)
            }
        }
        await ReadingStateSyncService.shared.start()
    }

    @MainActor
    private func applyReadingSyncSnapshot(_ snapshot: ReadingSyncSnapshot) {
        readingSyncPhase = snapshot.phase
        readingSyncLastSyncDate = snapshot.lastSyncDate
        readingSyncErrorDescription = snapshot.errorDescription

        if snapshot.clearsLocalCache {
            lastReadingRoute = nil
        } else if let state = snapshot.state {
            lastReadingRoute = state.route
        }
    }

    private static let syncStatusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
