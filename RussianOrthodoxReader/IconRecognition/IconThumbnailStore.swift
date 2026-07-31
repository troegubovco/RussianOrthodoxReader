#if canImport(UIKit)
import SwiftUI
import UIKit

/// Кэш эталонных изображений икон (BLOB → UIImage), читаемых из
/// `thumbs` таблицы `icon_meta.sqlite` через `IconMetaRepository`.
final class IconThumbnailStore {
    static let shared = IconThumbnailStore()

    private let cache = NSCache<NSNumber, UIImage>()
    private let missing = NSCache<NSNumber, NSNumber>()   // negative cache
    private let aspectCache = NSCache<NSNumber, NSNumber>()

    private init() {
        cache.countLimit = 80
        missing.countLimit = 200
    }

    /// Синхронно: чтение BLOB (~0.1 мс) + декод JPEG 192px (~1-2 мс). Кэшируется.
    /// `nil` when the icon has no thumbnail row (3/3158 subjects) or the
    /// `thumbs` table doesn't exist yet.
    func image(iconId: Int) -> UIImage? {
        let key = NSNumber(value: iconId)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if missing.object(forKey: key) != nil {
            return nil
        }
        guard let entry = IconMetaRepository.shared.thumbnailData(iconId: iconId),
              let image = UIImage(data: entry.data) else {
            missing.setObject(key, forKey: key)
            return nil
        }
        cache.setObject(image, forKey: key)
        aspectCache.setObject(NSNumber(value: Double(entry.width) / Double(max(entry.height, 1))), forKey: key)
        return image
    }

    /// Соотношение сторон из колонок w/h — для лэйаута без декода.
    func aspectRatio(iconId: Int) -> CGFloat {
        let key = NSNumber(value: iconId)
        if let cached = aspectCache.object(forKey: key) {
            return CGFloat(truncating: cached)
        }
        guard let entry = IconMetaRepository.shared.thumbnailData(iconId: iconId), entry.height > 0 else {
            return 0.75
        }
        let ratio = Double(entry.width) / Double(entry.height)
        aspectCache.setObject(NSNumber(value: ratio), forKey: key)
        return CGFloat(ratio)
    }
}

/// Тайл с эталонным изображением иконы. При отсутствии — SF Symbol "photo"
/// на приглушённом фоне.
struct IconThumbnailView: View {
    let iconId: Int
    var contentMode: ContentMode = .fit

    private let theme = OrthodoxColors.fallback

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.fastBackground)
            .overlay {
                if let image = IconThumbnailStore.shared.image(iconId: iconId) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .padding(4)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 16, weight: .light))
                        .foregroundColor(theme.muted.opacity(0.5))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.border, lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}
#endif
