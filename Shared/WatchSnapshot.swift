import Foundation

/// Снимок пользовательских данных молитвослова, который iPhone передаёт
/// на Apple Watch через WatchConnectivity (`updateApplicationContext`).
///
/// Часы только читают: «Моё правило», закладки и имена помянника
/// редактируются на телефоне. Снимок целиком заменяет предыдущий —
/// это последнее известное состояние, а не журнал изменений.
///
/// Контракт хранения на часах: приёмник кладёт JSON снимка в
/// `UserDefaults.standard` под ключом `userDefaultsKey` и рассылает
/// `didChangeNotification`; хранилище часов читает оттуда.
struct WatchSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let userDefaultsKey = "watch.userDataSnapshot"
    static let didChangeNotification = Notification.Name("WatchSnapshotDidChange")
    /// Ключ словаря applicationContext, под которым лежит JSON-Data снимка.
    static let contextKey = "snapshot"

    struct Entry: Codable, Equatable, Identifiable {
        var uuid: String
        /// PomyannikList.rawValue: "health" | "repose"
        var list: String
        var canonicalName: String
        var canonicalGen: String
        var canonicalAcc: String
        /// PersonGender.rawValue: "m" | "f"
        var gender: String
        /// PomyannikStatus.rawValue или nil
        var status: String?

        var id: String { uuid }

        var listValue: PomyannikList { PomyannikList(rawValue: list) ?? .health }
        var genderValue: PersonGender { PersonGender(rawValue: gender) ?? .male }
    }

    /// Плоский снимок одного плана чтения для часов — см. §4.6
    /// akathist_psalter_design.md. Часы только читают: отметка «прочитано»
    /// на часах уходит на телефон отдельным каналом
    /// (`WCSession.transferUserInfo`, `WatchSnapshotSender.session(_:didReceiveUserInfo:)`),
    /// а не правит этот снимок напрямую.
    struct Plan: Codable, Equatable, Identifiable {
        var uuid: String
        /// `ReadingPlanKind.rawKind`.
        var kind: String
        var subjectSlug: String?
        /// Готовая строка названия — часы не ходят в БД молитв за ней.
        var title: String
        var totalUnits: Int
        var completedCount: Int
        var doneToday: Bool
        var nextUnitIndex: Int
        var nextUnitLabel: String
        /// Что открыть кнопкой «Читать»; slug молитвы в молитвослове.
        var nextTargetSlug: String?

        var id: String { uuid }
    }

    var version: Int = WatchSnapshot.currentVersion
    var sentAt: Date
    var myRuleSlugs: [String]
    var bookmarkSlugs: [String]
    var pomyannik: [Entry]
    /// Настройки чтения телефона — используются на часах только как
    /// значения по умолчанию при первом запуске.
    var prayerLanguage: String?
    var showStress: Bool?
    /// ОПТИОНАЛ, не `= []` — см. §8.3: на часах может лежать снимок v1
    /// (`loadStored`), который отправлялся до появления этого поля. У
    /// синтезированного `init(from:)` значение по умолчанию не спасает от
    /// отсутствующего ключа — он бы бросил и часы потеряли бы правило,
    /// закладки и помянник до первой новой синхронизации. Оптионал даёт
    /// `decodeIfPresent` автоматически.
    var plans: [Plan]?

    func entries(in list: PomyannikList) -> [Entry] {
        pomyannik.filter { $0.list == list.rawValue }
    }

    // MARK: - Сериализация

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decode(_ data: Data) -> WatchSnapshot? {
        try? decoder.decode(WatchSnapshot.self, from: data)
    }

    /// Снимок, сохранённый на этом устройстве (часах), если он уже приходил.
    static func loadStored(from defaults: UserDefaults = .standard) -> WatchSnapshot? {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return nil }
        return decode(data)
    }
}

#if DEBUG
extension WatchSnapshot {
    /// Зафиксированный JSON снимка v1 — сериализован до появления `plans`,
    /// без этого ключа вовсе. Ровно то, что может лежать в
    /// `UserDefaults.standard` на часах после установки предыдущей версии
    /// приложения (§8.3).
    private static let v1FixtureJSON = """
    {
      "version": 1,
      "sentAt": "2026-01-01T00:00:00Z",
      "myRuleSlugs": ["utrennie.molitva-nachalnaya"],
      "bookmarkSlugs": ["akafisty.akafist-iisusu-sladchajshemu"],
      "pomyannik": [
        {"uuid":"fixture-1","list":"health","canonicalName":"Иоанн","canonicalGen":"Иоанна","canonicalAcc":"Иоанна","gender":"m","status":null}
      ],
      "prayerLanguage": "cs",
      "showStress": true
    }
    """

    /// Проверяет, что новый Codable-тип (с полем `plans`) по-прежнему
    /// декодирует старый снимок без этого ключа, и что `plans` при этом
    /// становится `nil`, а не бросает `DecodingError.keyNotFound`.
    static func runV1CompatibilitySelfTest() {
        guard let data = v1FixtureJSON.data(using: .utf8), let snapshot = decode(data) else {
            assertionFailure("WatchSnapshot: v1-снимок без \"plans\" не декодировался")
            return
        }
        assert(snapshot.plans == nil,
               "WatchSnapshot: plans должен быть nil при отсутствии ключа в снимке v1")
        assert(snapshot.myRuleSlugs == ["utrennie.molitva-nachalnaya"],
               "WatchSnapshot: myRuleSlugs не пережил decode снимка v1")
        assert(snapshot.bookmarkSlugs == ["akafisty.akafist-iisusu-sladchajshemu"],
               "WatchSnapshot: bookmarkSlugs не пережил decode снимка v1")
        assert(snapshot.pomyannik.count == 1,
               "WatchSnapshot: помянник не пережил decode снимка v1")
    }
}
#endif
