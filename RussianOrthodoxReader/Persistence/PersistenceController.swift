import Foundation
import SwiftData

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    private init(inMemory: Bool = false) {
        // В режиме скриншотов используем хранилище только в памяти, чтобы не
        // трогать реальные данные пользователя и стартовать с чистого листа.
        let inMemory = inMemory || ScreenshotMode.isActive
        let schema = Schema([
            LiturgicalDayEntity.self,
            ReadingReferenceEntity.self,
            PrayerBookmarkEntity.self,
            PomyannikEntryEntity.self,
            MyRuleItemEntity.self,
            ReadingPlanEntity.self,
            ReadingPlanUnitEntity.self
        ])

        // cloudKitDatabase: .none — this store is a local API cache and must not
        // sync via CloudKit. Without this, SwiftData sees the CloudKit entitlement
        // and tries to enable sync, which requires all attributes to be optional
        // and forbids unique constraints — incompatible with this schema.
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }

        if ScreenshotMode.isActive {
            seedScreenshotData()
        }
    }

    /// Заполняет помянник демонстрационными записями для скриншотов.
    /// Работает только поверх in-memory хранилища (см. init), поэтому
    /// идемпотентность не требуется — каждый запуск начинается с нуля.
    private func seedScreenshotData() {
        let context = container.mainContext

        struct Demo {
            let list: PomyannikList
            let name: String
            let gen: String
            let acc: String
            let gender: PersonGender
            let status: PomyannikStatus?
        }

        let demo: [Demo] = [
            .init(list: .health, name: "Сергий",   gen: "Сергия",   acc: "Сергия",   gender: .male,   status: nil),
            .init(list: .health, name: "Мария",    gen: "Марии",    acc: "Марию",    gender: .female, status: nil),
            .init(list: .health, name: "Николай",  gen: "Николая",  acc: "Николая",  gender: .male,   status: .sick),
            .init(list: .health, name: "Анна",     gen: "Анны",     acc: "Анну",     gender: .female, status: nil),
            .init(list: .health, name: "Иоанн",    gen: "Иоанна",   acc: "Иоанна",   gender: .male,   status: nil),
            .init(list: .repose, name: "Александр", gen: "Александра", acc: "Александра", gender: .male, status: .newlyDeparted),
            .init(list: .repose, name: "Елена",    gen: "Елены",    acc: "Елену",    gender: .female, status: nil),
            .init(list: .repose, name: "Пётр",     gen: "Петра",    acc: "Петра",    gender: .male,   status: nil),
        ]

        var order: [PomyannikList: Int] = [:]
        for item in demo {
            let sortOrder = order[item.list, default: 0]
            order[item.list] = sortOrder + 1
            context.insert(PomyannikEntryEntity(
                listRaw: item.list.rawValue,
                inputName: item.name,
                canonicalName: item.name,
                canonicalGen: item.gen,
                canonicalAcc: item.acc,
                genderRaw: item.gender.rawValue,
                status: item.status?.rawValue,
                sortOrder: sortOrder
            ))
        }
        try? context.save()
    }
    
    /// Creates a new background context for off-main-thread operations
    nonisolated func newBackgroundContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}
