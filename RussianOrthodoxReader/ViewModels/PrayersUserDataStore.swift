import Combine
import Foundation
import SwiftData
import SwiftUI

/// Единая точка записи пользовательских данных раздела «Молитвы»:
/// закладки и записи помянника. Все мутации проставляют modifiedAt
/// (ключ синхронизации) и уведомляют слой CloudKit-синка.
@MainActor
final class PrayersUserDataStore: ObservableObject {
    static let shared = PrayersUserDataStore()

    @Published private(set) var bookmarkSlugs: [String] = []
    @Published private(set) var myRuleSlugs: [String] = []
    @Published private(set) var entries: [PomyannikEntryEntity] = []

    private let context: ModelContext

    private init(context: ModelContext? = nil) {
        self.context = context ?? PersistenceController.shared.container.mainContext
        reload()
    }

    func reload() {
        let bookmarkDescriptor = FetchDescriptor<PrayerBookmarkEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        bookmarkSlugs = (try? context.fetch(bookmarkDescriptor))?.map(\.prayerSlug) ?? []

        let entryDescriptor = FetchDescriptor<PomyannikEntryEntity>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        entries = (try? context.fetch(entryDescriptor)) ?? []

        let ruleDescriptor = FetchDescriptor<MyRuleItemEntity>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        myRuleSlugs = (try? context.fetch(ruleDescriptor))?.map(\.prayerSlug) ?? []
    }

    // MARK: - Моё правило

    func isInMyRule(_ slug: String) -> Bool {
        myRuleSlugs.contains(slug)
    }

    func toggleMyRule(_ slug: String) {
        if let existing = fetchRuleItem(slug) {
            context.delete(existing)
            save()
            PrayersSyncHooks.didDeleteRuleItem?(slug)
        } else {
            let maxOrder = (try? context.fetch(FetchDescriptor<MyRuleItemEntity>()))?
                .map(\.sortOrder).max() ?? -1
            context.insert(MyRuleItemEntity(prayerSlug: slug, sortOrder: maxOrder + 1))
            save()
            PrayersSyncHooks.didSaveRuleItem?(slug)
        }
        reload()
    }

    /// Перестановка пунктов правила (drag-and-drop в списке).
    func moveMyRule(fromOffsets source: IndexSet, toOffset destination: Int) {
        var slugs = myRuleSlugs
        slugs.move(fromOffsets: source, toOffset: destination)
        let items = (try? context.fetch(FetchDescriptor<MyRuleItemEntity>())) ?? []
        for (index, slug) in slugs.enumerated() {
            if let item = items.first(where: { $0.prayerSlug == slug }),
               item.sortOrder != index {
                item.sortOrder = index
                item.modifiedAt = Date()
                PrayersSyncHooks.didSaveRuleItem?(slug)
            }
        }
        save()
        reload()
    }

    private func fetchRuleItem(_ slug: String) -> MyRuleItemEntity? {
        var descriptor = FetchDescriptor<MyRuleItemEntity>(
            predicate: #Predicate { $0.prayerSlug == slug })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Закладки

    func isBookmarked(_ slug: String) -> Bool {
        bookmarkSlugs.contains(slug)
    }

    func toggleBookmark(_ slug: String) {
        if let existing = fetchBookmark(slug) {
            context.delete(existing)
            save()
            syncDidDeleteBookmark(slug: slug)
        } else {
            let bookmark = PrayerBookmarkEntity(prayerSlug: slug)
            context.insert(bookmark)
            save()
            syncDidSaveBookmark(slug: slug)
        }
        reload()
    }

    private func fetchBookmark(_ slug: String) -> PrayerBookmarkEntity? {
        var descriptor = FetchDescriptor<PrayerBookmarkEntity>(
            predicate: #Predicate { $0.prayerSlug == slug })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Помянник

    func entries(in list: PomyannikList) -> [PomyannikEntryEntity] {
        entries.filter { $0.listRaw == list.rawValue }
    }

    func addEntry(list: PomyannikList,
                  inputName: String,
                  canonicalName: String,
                  canonicalGen: String,
                  canonicalAcc: String,
                  gender: PersonGender,
                  status: String? = nil) {
        let maxOrder = entries(in: list).map(\.sortOrder).max() ?? -1
        let entry = PomyannikEntryEntity(
            listRaw: list.rawValue,
            inputName: inputName,
            canonicalName: canonicalName,
            canonicalGen: canonicalGen,
            canonicalAcc: canonicalAcc,
            genderRaw: gender.rawValue,
            status: status,
            sortOrder: maxOrder + 1
        )
        context.insert(entry)
        save()
        syncDidSaveEntry(uuid: entry.uuid)
        reload()
    }

    func removeEntry(_ entry: PomyannikEntryEntity) {
        let uuid = entry.uuid
        context.delete(entry)
        save()
        syncDidDeleteEntry(uuid: uuid)
        reload()
    }

    /// Перенос записи в другой список (здравие ⇄ упокой).
    func moveEntry(_ entry: PomyannikEntryEntity, to list: PomyannikList) {
        guard entry.listRaw != list.rawValue else { return }
        entry.listRaw = list.rawValue
        // Статусы имеют смысл только в своём списке.
        if list == .repose {
            entry.status = PomyannikStatus.newlyDeparted.rawValue
        } else {
            entry.status = nil
        }
        entry.sortOrder = (entries(in: list).map(\.sortOrder).max() ?? -1) + 1
        entry.modifiedAt = Date()
        save()
        syncDidSaveEntry(uuid: entry.uuid)
        reload()
    }

    func updateEntry(_ entry: PomyannikEntryEntity,
                     inputName: String? = nil,
                     canonicalName: String? = nil,
                     canonicalGen: String? = nil,
                     canonicalAcc: String? = nil,
                     gender: PersonGender? = nil,
                     status: String?? = nil) {
        if let inputName { entry.inputName = inputName }
        if let canonicalName { entry.canonicalName = canonicalName }
        if let canonicalGen { entry.canonicalGen = canonicalGen }
        if let canonicalAcc { entry.canonicalAcc = canonicalAcc }
        if let gender { entry.genderRaw = gender.rawValue }
        if let status { entry.status = status }
        entry.modifiedAt = Date()
        save()
        syncDidSaveEntry(uuid: entry.uuid)
        reload()
    }

    // MARK: - Применение удалённых изменений (вызывается PrayersSyncService)

    func applyRemoteChanges() {
        reload()
    }

    // MARK: - Private

    private func save() {
        do {
            try context.save()
        } catch {
            print("PrayersUserDataStore: ошибка сохранения — \(error)")
        }
    }

    // Точки подключения CloudKit-синка (реализуются в PrayersSyncService).
    private func syncDidSaveBookmark(slug: String) {
        PrayersSyncHooks.didSaveBookmark?(slug)
    }

    private func syncDidDeleteBookmark(slug: String) {
        PrayersSyncHooks.didDeleteBookmark?(slug)
    }

    private func syncDidSaveEntry(uuid: String) {
        PrayersSyncHooks.didSaveEntry?(uuid)
    }

    private func syncDidDeleteEntry(uuid: String) {
        PrayersSyncHooks.didDeleteEntry?(uuid)
    }
}

/// Слабая связка store → sync: PrayersSyncService назначает обработчики
/// при старте; без него мутации просто остаются локальными.
@MainActor
enum PrayersSyncHooks {
    static var didSaveBookmark: ((String) -> Void)?
    static var didDeleteBookmark: ((String) -> Void)?
    static var didSaveEntry: ((String) -> Void)?
    static var didDeleteEntry: ((String) -> Void)?
    static var didSaveRuleItem: ((String) -> Void)?
    static var didDeleteRuleItem: ((String) -> Void)?
}
