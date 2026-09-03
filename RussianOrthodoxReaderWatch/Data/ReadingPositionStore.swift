//
//  ReadingPositionStore.swift
//  RussianOrthodoxReaderWatch
//
//  Позиция чтения на часах — под ключами watch.pos.* в UserDefaults.
//  Пишется при каждой смене фрагмента и при уходе с экрана чтения.
//  Читается корневым экраном для строки «Продолжить».
//

import Foundation

enum ReadingPositionStore {
    private static let refKey = "watch.pos.ref"
    private static let unitTitleKey = "watch.pos.unitTitle"
    private static let fragmentIndexKey = "watch.pos.fragmentIndex"
    private static let fragmentCountKey = "watch.pos.fragmentCount"
    private static let fragmentLabelKey = "watch.pos.fragmentLabel"
    private static let readAtKey = "watch.pos.readAt"

    /// «Продолжить» показываем только для позиции моложе этого срока.
    static let freshnessWindow: TimeInterval = 7 * 24 * 3600

    struct Saved {
        let ref: ReadingUnitRef
        let unitTitle: String
        let fragmentIndex: Int
        let fragmentCount: Int
        let fragmentLabel: String
        let readAt: Date
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func save(ref: ReadingUnitRef,
                      unitTitle: String,
                      fragmentIndex: Int,
                      fragmentCount: Int,
                      fragmentLabel: String,
                      defaults: UserDefaults = .standard) {
        guard let data = try? encoder.encode(ref),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: refKey)
        defaults.set(unitTitle, forKey: unitTitleKey)
        defaults.set(fragmentIndex, forKey: fragmentIndexKey)
        defaults.set(fragmentCount, forKey: fragmentCountKey)
        defaults.set(fragmentLabel, forKey: fragmentLabelKey)
        defaults.set(Date().timeIntervalSince1970, forKey: readAtKey)
    }

    static func load(defaults: UserDefaults = .standard) -> Saved? {
        guard let json = defaults.string(forKey: refKey),
              let data = json.data(using: .utf8),
              let ref = try? decoder.decode(ReadingUnitRef.self, from: data)
        else { return nil }

        let readAtInterval = defaults.double(forKey: readAtKey)
        guard readAtInterval > 0 else { return nil }

        return Saved(
            ref: ref,
            unitTitle: defaults.string(forKey: unitTitleKey) ?? "",
            fragmentIndex: defaults.integer(forKey: fragmentIndexKey),
            fragmentCount: defaults.integer(forKey: fragmentCountKey),
            fragmentLabel: defaults.string(forKey: fragmentLabelKey) ?? "",
            readAt: Date(timeIntervalSince1970: readAtInterval)
        )
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: refKey)
        defaults.removeObject(forKey: unitTitleKey)
        defaults.removeObject(forKey: fragmentIndexKey)
        defaults.removeObject(forKey: fragmentCountKey)
        defaults.removeObject(forKey: fragmentLabelKey)
        defaults.removeObject(forKey: readAtKey)
    }

    static func isFresh(_ saved: Saved, now: Date = Date()) -> Bool {
        now.timeIntervalSince(saved.readAt) < freshnessWindow
    }
}
