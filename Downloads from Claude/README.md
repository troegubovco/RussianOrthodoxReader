# Православное Чтение (Orthodox Reader) — v0.2

## Что нового в v0.2

### 1. Azbyka.ru Calendar API (вместо orthocal)

Календарные данные теперь берутся с **Азбуки веры** (`azbyka.ru/days`).

**Два режима работы:**

- **Виджет (без регистрации)** — endpoint `https://azbyka.ru/days/widgets/presentations.json`
  - Работает сразу, без API-ключа
  - Отдаёт: святых дня, праздники, иконку дня
  - НЕ отдаёт: чтения (Апостол/Евангелие), пост, глас
  
- **Полный API (после регистрации)** — endpoint `https://azbyka.ru/days/api/daytype/{date}.json`
  - Требует API-ключ (Bearer token)
  - Отдаёт ВСЁ: чтения, пост, святых, праздники, иконы, глас, седмицу

**Как зарегистрироваться:**
1. Перейти на https://azbyka.ru/days/register/userapi
2. Заполнить форму (указать «Православное Чтение, iOS приложение»)
3. Подтвердить email
4. Дождаться одобрения администратора
5. Ввести ключ в Настройки → Ключ API

API-ключ вводится в приложении: Настройки → Источник календаря → Добавить ключ.

**Файл:** `Services/AzbykaCalendarService.swift`

### 2. Сохранение состояния вкладок

При переключении между табами теперь сохраняется:
- Позиция прокрутки
- Выбранный элемент (день в календаре, книга/глава в Библии)
- Полный стек навигации (если вы были внутри ReaderView — он останется)

**Техническая реализация:** Вместо условного рендеринга (`if/else`) все 4 вкладки
рендерятся одновременно и переключаются через `opacity` + `allowsHitTesting`.
Каждая вкладка имеет свой `TabNavigationState` с `NavigationPath`.

**Файлы:** `App/AppState.swift`, `Views/ContentView.swift`

### 3. Двойное нажатие на вкладку = возврат на «домашний» экран

- Одно нажатие на текущую вкладку — ничего не происходит
- Два быстрых нажатия (< 350мс) — сброс вкладки в корневое состояние:
  - **Библия**: список книг (сворачивается выбранная книга, закрывается Reader)
  - **Календарь**: текущий месяц, снимается выбранный день
  - **Сегодня**: сброс навигации к корню
  - **Настройки**: сброс навигации к корню

**Файлы:** `App/AppState.swift` (`handleTabTap`), `Views/ContentView.swift` (`TabBarButton`)

---

## Структура проекта

```
OrthodoxReader/
├── App/
│   ├── OrthodoxReaderApp.swift       # Точка входа
│   └── AppState.swift                # Глобальное состояние + TabNavigationState
├── Services/
│   └── AzbykaCalendarService.swift   # Azbyka.ru API клиент (widget + full API)
├── Views/
│   ├── ContentView.swift             # Главный экран: табы с сохранением состояния
│   ├── TodayView.swift               # Экран «Сегодня» — данные из AzbykaService
│   ├── BibleView.swift               # Библия: 77 книг, навигация через NavigationStack
│   ├── CalendarView.swift            # Календарь: месячный вид, данные из AzbykaService
│   ├── SettingsView.swift            # Настройки + ввод API ключа
│   └── PrayerOverlay.swift           # Молитва перед чтением
└── Resources/
    └── (шрифты, БД Библии)
```

## Как запустить

### 1. Создайте Xcode проект
- File → New → Project → iOS App
- Назовите `OrthodoxReader`
- Interface: SwiftUI, Language: Swift
- Minimum deployment: iOS 17.0

### 2. Добавьте файлы
Скопируйте все `.swift` файлы из соответствующих папок в Xcode проект.

### 3. Добавьте шрифт Cormorant Garamond
1. Скачайте с [Google Fonts](https://fonts.google.com/specimen/Cormorant+Garamond)
2. Добавьте `.ttf` в проект
3. В Info.plist добавьте `Fonts provided by application`:
   - CormorantGaramond-Regular.ttf
   - CormorantGaramond-Medium.ttf
   - CormorantGaramond-SemiBold.ttf
   - CormorantGaramond-Bold.ttf
   - CormorantGaramond-Italic.ttf

### 4. Запустите
Cmd+R — приложение заработает с виджетным API (без ключа).
Для полных данных — зарегистрируйтесь и введите ключ в Настройках.

## Следующие шаги

- [ ] Получить API-ключ azbyka.ru
- [ ] Подключить SQLite базу Синодального перевода (trevarj/rsb)
- [ ] Молитвослов святым
- [ ] Распознавание икон (CoreML/Vision)
- [ ] Кэширование API-данных в локальную БД для оффлайн-работы
