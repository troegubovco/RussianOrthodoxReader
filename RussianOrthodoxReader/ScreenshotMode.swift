import Foundation

/// Режим для съёмки скриншотов App Store.
///
/// Включается флагом запуска `-screenshotMode` (задаётся в схеме Xcode:
/// Product → Scheme → Edit Scheme → Run → Arguments → «Arguments Passed On Launch»).
///
/// В этом режиме:
///  • хранилище SwiftData создаётся **только в памяти** — реальные данные на
///    устройстве не трогаются и не перезаписываются;
///  • CloudKit-синхронизация (и помянника, и позиции чтения) **не запускается**,
///    поэтому личные записи из iCloud не подтягиваются;
///  • помянник заполняется нейтральными демонстрационными именами, чтобы список
///    на скриншоте выглядел естественно.
enum ScreenshotMode {
    static let isActive: Bool =
        CommandLine.arguments.contains("-screenshotMode")
}
