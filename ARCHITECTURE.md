# ARCHITECTURE

Карта репозитория «Синодал» (RussianOrthodoxReader) — что где лежит и почему.
Это не журнал изменений: история живёт в [WORKLOG.md](WORKLOG.md). Здесь только
устойчивая структура — точки входа, стадии конвейеров и общие утилиты.

Репозиторий состоит из двух половин:

1. **§1 Приложение** — SwiftUI-клиент под iOS 16+ (и macOS-сборка), читает
   только заранее собранные SQLite-базы из бандла.
2. **§2 Офлайн-конвейеры** — Python в `Tools/`, который эти базы и ML-модели
   производит. Ничего из `Tools/` не выполняется на устройстве.

Контракт между половинами — файлы в `RussianOrthodoxReader/Resources/`.
Конвейер пишет их, приложение читает. Менять схему нужно с обеих сторон.

---

## §1. Приложение (`RussianOrthodoxReader/`)

### Точка входа и оболочка

| Файл | Роль |
| --- | --- |
| `RussianOrthodoxReaderApp.swift` | `@main`, поднимает `AppState` и SwiftData-контейнер |
| `ContentView.swift` | Корневой `ZStack`: слой вкладок + слой `ReaderView` + `PrayerOverlay`. Собственный `TabBarView` вместо нативного `TabView` |
| `AppState.swift` | `ObservableObject` уровня приложения: активная вкладка, `fontSize`, `fontFamily`, логика молитвы, `dayChangeTrigger` |
| `DesignSystem.swift` | Цвета, `AppFont`, `AppTypography`, environment-ключ `\.userFontSize`, view-модификаторы |
| `PlatformTypes.swift` | Псевдонимы типов, чтобы один и тот же код собирался под iOS и macOS |
| `ScreenshotMode.swift` | Детерминированное состояние для съёмки скриншотов в App Store |

Переключение вкладок — не `TabView`, а `ZStack` с `opacity` /
`allowsHitTesting`. Все четыре вкладки всегда в иерархии, поэтому их состояние
(и позиция скролла в читалке) переживает переключение. Флаг
`isReadingMode: Bool` в `ContentView` решает, какой слой видим.

### Экраны вкладок

`TodayView.swift`, `BibleView.swift`, `CalendarView.swift`, `PrayersView.swift`,
`SettingsView.swift`. Плюс `ReaderView.swift` (чтение Писания, кнопка словаря
в шапке), `DictionaryLookupView.swift`, `MyRuleView.swift`,
`SelectableTextView.swift` и `PrayersMacView.swift` для macOS-раскладки.

### ViewModels (`ViewModels/`)

| Файл | Роль |
| --- | --- |
| `ReaderViewModel.swift` | Асинхронная загрузка главы, фоновый предзагруз соседних глав (N±1) |
| `TodayViewModel.swift` | Состав экрана «Сегодня»: чтения дня и святые |
| `CalendarViewModel.swift` | Месячная сетка, пасхальные смещения |
| `PrayersUserDataStore.swift` | Закладки молитв и записи помянника поверх SwiftData |

### Слой данных (`Data/`)

Каждый репозиторий — обёртка над одной базой из бандла; UI не трогает SQLite
напрямую.

| Файл | Роль |
| --- | --- |
| `BibleSQLiteRepository.swift` | Синодальный текст; кэш глав в памяти по ключу `"bookId-chapter"` |
| `DictionaryRepository.swift` | Библейский словарь Нюстрема + падение на 60 встроенных статей |
| `PrayersRepository.swift` | Молитвослов из `prayers.sqlite` |
| `PrayerTemplateRenderer.swift` | Подстановка имён из помянника в шаблоны молитв |
| `ChurchNamesRepository.swift` | Церковные имена и их формы |
| `RussianNameDecliner.swift` | Склонение имён по падежам для помянника |
| `LiturgicalRepository.swift` | Фасад над источниками календаря; порядок: кэш SwiftData → `BundledLiturgicalDB` → `AzbykaAPIClient` |
| `BundledLiturgicalDB.swift` | Основной источник: `liturgical_calendar.sqlite`, поиск по пасхальному смещению |
| `AzbykaAPIClient.swift` | Только запасной сетевой путь для дат вне диапазона смещений |
| `OrthocalDTOs.swift` | DTO ответов календаря |
| `ReadingReferenceParser.swift` | Разбор ссылок на чтения: диапазоны глав/стихов, межглавные переносы, запятые-продолжения |
| `BookAliasMapper.swift` | Русские сокращения книг (в т.ч. в стиле Азбуки: `1Сол`, `2Сол`) |
| `FeatureFlags.swift` | Переключатели времени сборки (`useRealReadings`) |
| `LiturgicalCalendar.swift` (корень) | `PaschalCalculator` и вычисление юлианско-григорианского сдвига |

### Persistence и синхронизация

`Persistence/PersistenceController.swift` поднимает SwiftData-стек;
`LiturgicalDayEntity`, `ReadingReferenceEntity`, `PomyannikEntryEntity`,
`PrayerBookmarkEntity`, `MyRuleItemEntity` — модели.

Синхронизация — два независимых `CKSyncEngine` в приватной базе CloudKit:
`ReadingStateSync.swift` (+ `CloudSyncManager.swift`) для позиции чтения и
`PrayersSyncService.swift` для помянника и закладок. Разрешение конфликтов —
last-write-wins по времени с окном слияния, предпочитающим дальний прогресс.
`ReadingReminderScheduler.swift` планирует ежедневные локальные уведомления.

### Распознавание икон (`IconRecognition/`)

Съёмка иконы камерой → определение сюжета. Классификатор iOS-only (`Vision` /
`UIImage`), индекс прототипов и метаданные — кроссплатформенные.

| Файл | Роль |
| --- | --- |
| `IconRecognizer.swift` | Обёртка над `IconClassifier.mlpackage`; softmax-порог τ=0.60, косинусный порог 0.45. `shared` опционален — `nil`, если артефакты не в бандле |
| `PrototypeIndex.swift` | Косинусный поиск по `icon_prototypes.f32`/`.json` для сюжетов ниже порога |
| `IconMetaRepository.swift` | Справки о сюжетах из `icon_meta.sqlite` |
| `IconScanView.swift` / `IconResultView.swift` | Экран съёмки и экран результата с альтернативами |

### Ресурсы (`Resources/`) — контракт с конвейерами

`Bible/` (текст Писания и словарь), `prayers.sqlite`, `church_names.sqlite`,
`liturgical_calendar.sqlite`, `IconML/` (`icon_meta.sqlite`,
`icon_prototypes.f32`, `icon_prototypes.json`) и `IconClassifier.mlpackage`.

> Внимание: папка приложения подключена как synchronized group Xcode — любой
> не-исходный файл, положенный в неё, попадает в бандл. Промежуточные артефакты
> держите в `Tools/`.

### Типографика

`AppTypography(base:)` выводит всю шкалу из выбранного пользователем размера
(25–52pt, по умолчанию 33pt): micro 0.42x, caption 0.48x, footnote 0.55x,
subheadline 0.65x, callout 0.76x, body 1.0x, headline 1.06x, title 1.18x.
Размер приходит через `\.userFontSize`, инжектится в корне `ContentView`.
Текст и иконки таб-бара шкалированию не подлежат.

---

## §2. Офлайн-конвейеры (`Tools/`)

Запускаются вручную на машине разработчика; результат — файлы в
`Resources/`. Сырые данные и промежуточные артефакты — в `Tools/data/`.

### Сборка баз

| Скрипт / папка | Стадия |
| --- | --- |
| `build_bible_db/` | Синодальный текст → `Bible/*.sqlite` |
| `build_dictionary_v2/` | Актуальный четырёхпроходный конвейер словаря: 6 826 статей + 16 681 отображение форма→лемма |
| `build_dictionary/` | Предыдущее поколение словаря, оставлено для сверки |
| `parse_opencorpora_conjugations.py` | Формы слов из OpenCorpora для поиска по словоформам |
| `scrape_liturgical_calendar.py` → `build_liturgical_db.py` | Азбука.ру → `liturgical_calendar.sqlite` (святые по дате, чтения/глас/пост по пасхальному смещению −131…+255) |
| `scrape_molitvoslov.py` → `build_prayers_db.py` | Молитвослов → `prayers.sqlite` |
| `build_names_db.py` | Церковные имена и склонения → `church_names.sqlite` |
| `parse_church_slavonic_rtf.py`, `import_church_slavonic.py`, `enrich_church_slavonic.py` | Импорт и обогащение церковнославянского словаря |
| `build_icons_db.py` | Сборка справочника икон |

### Конвейер распознавания икон (`Tools/icon_ml/`)

Пронумерованные стадии выполняются по порядку; `PLAN.md` и `README.md`
описывают замысел и запуск, `common.py` / `icon_dataset.py` /
`icon_model.py` — общий код между стадиями.

| Стадия | Что делает |
| --- | --- |
| `01_build_manifest.py` | Манифест изображений из выгрузки Pravicon |
| `02_make_cache.py` | Предобработанный кэш тензоров |
| `03_dedupe.py` | Отсев дублей |
| `04_make_splits.py` | Разбиение train/val/test |
| `05_train.py` | Обучение классификатора |
| `06_evaluate.py` | Метрики и подбор τ (текущая модель: 64.8% top-1 при τ=0.6) |
| `07_export_coreml.py` | Экспорт в `IconClassifier.mlpackage` |
| `08_build_embedding_index.py` | `icon_prototypes.f32` / `.json` для косинусного поиска |
| `09_scrape_azbyka.py` | Описания сюжетов с Азбуки |
| `10_build_meta_db.py` | `icon_meta.sqlite` |
| `11_verify_release.py` | Проверка, что артефакты консистентны перед вкладыванием в бандл |

Скачивание исходников — `scrape_pravicon_index.py`,
`scrape_pravicon_details.py`, `download_pravicon_images.py`.

---

## Прочее

`docs/` — заметки по реализации, оптимизациям и хостинг-страницы (политика
приватности, поддержка). `AZBYKA_MIGRATION_NOTES.md` — история перехода на
Азбуку как источник календаря. `IconClassifier.mlproj` — проект Create ML,
оставленный от ранних экспериментов; продакшн-модель собирает
`Tools/icon_ml/07_export_coreml.py`.
