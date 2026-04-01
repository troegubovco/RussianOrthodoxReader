import Combine
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class IconIdentificationViewModel: ObservableObject {
    @Published private(set) var previewImage: PlatformImage?
    @Published private(set) var matches: [IconMatch] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var isAnalyzing = false
    @Published var errorMessage: String?

    private var hasPreparedAssets = false
    private let identifier: IconIdentifier

    init(identifier: IconIdentifier = .shared) {
        self.identifier = identifier
    }

    func prepareIfNeeded() async {
        guard !hasPreparedAssets, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        do {
            try await identifier.preload()
            hasPreparedAssets = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func identify(imageData: Data) async {
        guard let image = PlatformImage(data: imageData) else {
            errorMessage = "Не удалось открыть выбранное изображение."
            return
        }
        await identify(image: image)
    }

    func identify(image: PlatformImage) async {
        previewImage = image
        errorMessage = nil
        matches = []

        guard let cgImage = image.normalizedCGImage() else {
            errorMessage = "Не удалось подготовить изображение для распознавания."
            return
        }

        isAnalyzing = true
        defer { isAnalyzing = false }

        do {
            try await identifier.preload()
            matches = try await identifier.identify(cgImage, limit: 6)
            hasPreparedAssets = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearResults() {
        previewImage = nil
        matches = []
        errorMessage = nil
    }
}
