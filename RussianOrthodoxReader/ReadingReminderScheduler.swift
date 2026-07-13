import Foundation
import UserNotifications
import os.log

/// Планирует ежедневные локальные напоминания о чтениях следующего дня
/// («Напоминание накануне»). Уведомления создаются на неделю вперёд и
/// обновляются при запуске, смене дня и изменении настроек.
@MainActor
final class ReadingReminderScheduler {
    static let shared = ReadingReminderScheduler()

    enum AuthState: Equatable {
        case notDetermined
        case denied
        case authorized
    }

    private static let requestIDPrefix = "reading-reminder-"
    private static let daysAhead = 7
    static let defaultTime = (hour: 20, minute: 0)

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "OG.RussianOrthodoxReader", category: "ReadingReminder")

    private init() {}

    func currentAuthState() async -> AuthState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Сериализует вызовы applySettings, чтобы параллельные обновления
    /// не перемешивали удаление и добавление уведомлений.
    private var applyChain: Task<AuthState, Never>?

    /// Применяет настройки пользователя: при включении планирует напоминания,
    /// при выключении удаляет их. Системный запрос разрешения показывается
    /// только когда `allowPermissionPrompt == true` (явное действие в настройках).
    @discardableResult
    func applySettings(enabled: Bool, time: String, allowPermissionPrompt: Bool) async -> AuthState {
        let previous = applyChain
        let task = Task { () -> AuthState in
            _ = await previous?.value
            return await self.performApply(enabled: enabled, time: time, allowPermissionPrompt: allowPermissionPrompt)
        }
        applyChain = task
        return await task.value
    }

    private func performApply(enabled: Bool, time: String, allowPermissionPrompt: Bool) async -> AuthState {
        var state = await currentAuthState()

        guard enabled else {
            await removePendingReminders()
            return state
        }

        if state == .notDetermined && allowPermissionPrompt {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            state = granted ? .authorized : .denied
        }

        guard state == .authorized else {
            await removePendingReminders()
            return state
        }

        await reschedule(time: time)
        return state
    }

    // MARK: - Scheduling

    private func removePendingReminders() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.requestIDPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func reschedule(time: String) async {
        await removePendingReminders()

        let (hour, minute) = Self.parseTime(time)
        let calendar = Calendar.current
        let now = Date()

        for offset in 0..<Self.daysAhead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let fireDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fireDate > now,
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day)
            else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Чтения на завтра"
            content.body = await reminderBody(for: nextDay)
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let request = UNNotificationRequest(
                identifier: Self.requestIDPrefix + LiturgicalRepository.dateKey(from: day),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )

            do {
                try await center.add(request)
            } catch {
                logger.error("Не удалось запланировать напоминание: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func reminderBody(for date: Date) async -> String {
        guard let day = try? await LiturgicalRepository.shared.getDay(date: date) else {
            return "Откройте завтрашние чтения в приложении"
        }

        var parts: [String] = []
        if day.apostolReading != "—" {
            parts.append("Апостол: \(day.apostolReading)")
        }
        if day.gospelReading != "—" {
            parts.append("Евангелие: \(day.gospelReading)")
        }

        guard !parts.isEmpty else {
            return day.saintOfDay
        }
        return parts.joined(separator: " · ")
    }

    private static func parseTime(_ value: String) -> (hour: Int, minute: Int) {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute) else {
            return defaultTime
        }
        return (hour, minute)
    }
}
