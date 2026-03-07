import Foundation
import SwiftData

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    private init(inMemory: Bool = false) {
        let schema = Schema([
            LiturgicalDayEntity.self,
            ReadingReferenceEntity.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
    }
    
    /// Creates a new background context for off-main-thread operations
    nonisolated func newBackgroundContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}
