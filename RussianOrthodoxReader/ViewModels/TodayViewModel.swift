import Foundation
import Combine

@MainActor
final class TodayViewModel: ObservableObject {
    @Published var day: LiturgicalDay?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let repository: LiturgicalRepositoryProtocol

    init(repository: LiturgicalRepositoryProtocol) {
        self.repository = repository
    }

    convenience init() {
        self.init(repository: LiturgicalRepository.shared)
    }

    func loadToday() async {
        await load(date: Date())
    }

    func load(date: Date) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let value = try await repository.getDay(date: date)
            day = value
            errorMessage = value.dataAvailabilityMessage
        } catch {
            day = nil
            errorMessage = error.localizedDescription
        }
    }

    func prefetch() async {
        await repository.prefetchWindow(centerDate: Date())
    }
}

