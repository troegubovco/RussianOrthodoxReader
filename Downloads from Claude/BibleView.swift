import SwiftUI

struct BibleView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tabState: TabNavigationState
    
    private let theme = OrthodoxTheme.shared
    
    var body: some View {
        NavigationStack(path: $tabState.navigationPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Title
                        Text("Библия")
                            .font(.custom("CormorantGaramond-SemiBold", size: 28))
                            .foregroundColor(theme.text)
                            .padding(.top, 60)
                        
                        // Testament toggle
                        testamentPicker
                        
                        // Book list
                        bookList
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
                }
                .background(Color(hex: "FAF8F5"))
                .onChange(of: tabState.scrollAnchorID) { _, newValue in
                    if let anchor = newValue {
                        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                    }
                }
            }
            .navigationDestination(for: BibleDestination.self) { destination in
                switch destination {
                case .chapter(let bookKey, let chapter):
                    ReaderView(bookKey: bookKey, chapter: chapter)
                        .environmentObject(appState)
                }
            }
        }
    }
    
    // MARK: - Testament Picker
    
    private var testamentPicker: some View {
        HStack(spacing: 0) {
            ForEach(BibleTestament.allCases, id: \.self) { testament in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        tabState.selectedBibleTestament = testament
                    }
                } label: {
                    Text(testament.rawValue)
                        .font(.custom("CormorantGaramond-Medium", size: 15))
                        .foregroundColor(
                            tabState.selectedBibleTestament == testament
                                ? .white
                                : theme.muted
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            tabState.selectedBibleTestament == testament
                                ? theme.accent
                                : .clear
                        )
                        .clipShape(Capsule())
                }
                .accessibilityAddTraits(
                    tabState.selectedBibleTestament == testament ? .isSelected : []
                )
            }
        }
        .padding(3)
        .background(theme.border)
        .clipShape(Capsule())
    }
    
    // MARK: - Book List
    
    private var bookList: some View {
        let books = tabState.selectedBibleTestament == .new
            ? BibleData.newTestamentBooks
            : BibleData.oldTestamentBooks
        
        return VStack(spacing: 2) {
            ForEach(books) { book in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if tabState.selectedBibleBook == book.key {
                            tabState.selectedBibleBook = nil
                        } else {
                            tabState.selectedBibleBook = book.key
                        }
                    }
                } label: {
                    HStack {
                        Text(book.name)
                            .font(.custom("CormorantGaramond-Regular", size: 17))
                            .foregroundColor(theme.text)
                        
                        Spacer()
                        
                        Text("\(book.chapters) гл.")
                            .font(.custom("CormorantGaramond-Regular", size: 14))
                            .foregroundColor(theme.muted)
                        
                        Image(systemName:
                            tabState.selectedBibleBook == book.key
                                ? "chevron.down"
                                : "chevron.right"
                        )
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .id(book.key)
                
                // Expanded chapter grid
                if tabState.selectedBibleBook == book.key {
                    chapterGrid(book: book)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
    
    // MARK: - Chapter Grid
    
    private func chapterGrid(book: BibleBook) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
        
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(1...book.chapters, id: \.self) { chapter in
                Button {
                    // Check prayer before opening
                    if appState.requestReading() {
                        tabState.navigationPath.append(
                            BibleDestination.chapter(bookKey: book.key, chapter: chapter)
                        )
                    }
                } label: {
                    Text("\(chapter)")
                        .font(.custom("CormorantGaramond-Medium", size: 16))
                        .foregroundColor(theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(theme.todayBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Navigation Destination

enum BibleDestination: Hashable {
    case chapter(bookKey: String, chapter: Int)
}

// MARK: - Bible Data Models

struct BibleBook: Identifiable {
    let key: String
    let name: String
    let abbreviation: String
    let chapters: Int
    
    var id: String { key }
}

struct BibleData {
    static let newTestamentBooks: [BibleBook] = [
        BibleBook(key: "mat", name: "Евангелие от Матфея", abbreviation: "Мф", chapters: 28),
        BibleBook(key: "mrk", name: "Евангелие от Марка", abbreviation: "Мк", chapters: 16),
        BibleBook(key: "luk", name: "Евангелие от Луки", abbreviation: "Лк", chapters: 24),
        BibleBook(key: "jhn", name: "Евангелие от Иоанна", abbreviation: "Ин", chapters: 21),
        BibleBook(key: "act", name: "Деяния Апостолов", abbreviation: "Деян", chapters: 28),
        BibleBook(key: "rom", name: "Послание к Римлянам", abbreviation: "Рим", chapters: 16),
        BibleBook(key: "1co", name: "1-е Коринфянам", abbreviation: "1Кор", chapters: 16),
        BibleBook(key: "2co", name: "2-е Коринфянам", abbreviation: "2Кор", chapters: 13),
        BibleBook(key: "gal", name: "Галатам", abbreviation: "Гал", chapters: 6),
        BibleBook(key: "eph", name: "Ефесянам", abbreviation: "Еф", chapters: 6),
        BibleBook(key: "phi", name: "Филиппийцам", abbreviation: "Флп", chapters: 4),
        BibleBook(key: "col", name: "Колоссянам", abbreviation: "Кол", chapters: 4),
        BibleBook(key: "1th", name: "1-е Фессалоникийцам", abbreviation: "1Фес", chapters: 5),
        BibleBook(key: "2th", name: "2-е Фессалоникийцам", abbreviation: "2Фес", chapters: 3),
        BibleBook(key: "1ti", name: "1-е Тимофею", abbreviation: "1Тим", chapters: 6),
        BibleBook(key: "2ti", name: "2-е Тимофею", abbreviation: "2Тим", chapters: 4),
        BibleBook(key: "tit", name: "Титу", abbreviation: "Тит", chapters: 3),
        BibleBook(key: "phm", name: "Филимону", abbreviation: "Флм", chapters: 1),
        BibleBook(key: "heb", name: "Евреям", abbreviation: "Евр", chapters: 13),
        BibleBook(key: "jas", name: "Иакова", abbreviation: "Иак", chapters: 5),
        BibleBook(key: "1pe", name: "1-е Петра", abbreviation: "1Пет", chapters: 5),
        BibleBook(key: "2pe", name: "2-е Петра", abbreviation: "2Пет", chapters: 3),
        BibleBook(key: "1jn", name: "1-е Иоанна", abbreviation: "1Ин", chapters: 5),
        BibleBook(key: "2jn", name: "2-е Иоанна", abbreviation: "2Ин", chapters: 1),
        BibleBook(key: "3jn", name: "3-е Иоанна", abbreviation: "3Ин", chapters: 1),
        BibleBook(key: "jud", name: "Иуды", abbreviation: "Иуд", chapters: 1),
        BibleBook(key: "rev", name: "Откровение Иоанна", abbreviation: "Откр", chapters: 22),
    ]
    
    static let oldTestamentBooks: [BibleBook] = [
        BibleBook(key: "gen", name: "Бытие", abbreviation: "Быт", chapters: 50),
        BibleBook(key: "exo", name: "Исход", abbreviation: "Исх", chapters: 40),
        BibleBook(key: "lev", name: "Левит", abbreviation: "Лев", chapters: 27),
        BibleBook(key: "num", name: "Числа", abbreviation: "Чис", chapters: 36),
        BibleBook(key: "deu", name: "Второзаконие", abbreviation: "Втор", chapters: 34),
        BibleBook(key: "jos", name: "Иисус Навин", abbreviation: "Нав", chapters: 24),
        BibleBook(key: "jdg", name: "Судей", abbreviation: "Суд", chapters: 21),
        BibleBook(key: "rut", name: "Руфь", abbreviation: "Руфь", chapters: 4),
        BibleBook(key: "1sa", name: "1-я Царств", abbreviation: "1Цар", chapters: 31),
        BibleBook(key: "2sa", name: "2-я Царств", abbreviation: "2Цар", chapters: 24),
        BibleBook(key: "1ki", name: "3-я Царств", abbreviation: "3Цар", chapters: 22),
        BibleBook(key: "2ki", name: "4-я Царств", abbreviation: "4Цар", chapters: 25),
        BibleBook(key: "1ch", name: "1-я Паралипоменон", abbreviation: "1Пар", chapters: 29),
        BibleBook(key: "2ch", name: "2-я Паралипоменон", abbreviation: "2Пар", chapters: 36),
        BibleBook(key: "ezr", name: "Ездра", abbreviation: "Езд", chapters: 10),
        BibleBook(key: "neh", name: "Неемия", abbreviation: "Неем", chapters: 13),
        BibleBook(key: "est", name: "Есфирь", abbreviation: "Есф", chapters: 10),
        BibleBook(key: "job", name: "Иов", abbreviation: "Иов", chapters: 42),
        BibleBook(key: "psa", name: "Псалтирь", abbreviation: "Пс", chapters: 150),
        BibleBook(key: "pro", name: "Притчи Соломона", abbreviation: "Притч", chapters: 31),
        BibleBook(key: "ecc", name: "Екклесиаст", abbreviation: "Еккл", chapters: 12),
        BibleBook(key: "sng", name: "Песнь Песней", abbreviation: "Песн", chapters: 8),
        BibleBook(key: "isa", name: "Исаия", abbreviation: "Ис", chapters: 66),
        BibleBook(key: "jer", name: "Иеремия", abbreviation: "Иер", chapters: 52),
        BibleBook(key: "lam", name: "Плач Иеремии", abbreviation: "Плач", chapters: 5),
        BibleBook(key: "ezk", name: "Иезекииль", abbreviation: "Иез", chapters: 48),
        BibleBook(key: "dan", name: "Даниил", abbreviation: "Дан", chapters: 12),
        BibleBook(key: "hos", name: "Осия", abbreviation: "Ос", chapters: 14),
        BibleBook(key: "jol", name: "Иоиль", abbreviation: "Иоил", chapters: 3),
        BibleBook(key: "amo", name: "Амос", abbreviation: "Ам", chapters: 9),
        BibleBook(key: "oba", name: "Авдий", abbreviation: "Авд", chapters: 1),
        BibleBook(key: "jon", name: "Иона", abbreviation: "Ион", chapters: 4),
        BibleBook(key: "mic", name: "Михей", abbreviation: "Мих", chapters: 7),
        BibleBook(key: "nah", name: "Наум", abbreviation: "Наум", chapters: 3),
        BibleBook(key: "hab", name: "Аввакум", abbreviation: "Авв", chapters: 3),
        BibleBook(key: "zep", name: "Софония", abbreviation: "Соф", chapters: 3),
        BibleBook(key: "hag", name: "Аггей", abbreviation: "Агг", chapters: 2),
        BibleBook(key: "zec", name: "Захария", abbreviation: "Зах", chapters: 14),
        BibleBook(key: "mal", name: "Малахия", abbreviation: "Мал", chapters: 4),
        // Deuterocanonical (in Orthodox canon)
        BibleBook(key: "tob", name: "Товит", abbreviation: "Тов", chapters: 14),
        BibleBook(key: "jdt", name: "Иудифь", abbreviation: "Иудиф", chapters: 16),
        BibleBook(key: "wis", name: "Премудрость Соломона", abbreviation: "Прем", chapters: 19),
        BibleBook(key: "sir", name: "Премудрость Сираха", abbreviation: "Сир", chapters: 51),
        BibleBook(key: "bar", name: "Варух", abbreviation: "Вар", chapters: 5),
        BibleBook(key: "1ma", name: "1-я Маккавейская", abbreviation: "1Мак", chapters: 16),
        BibleBook(key: "2ma", name: "2-я Маккавейская", abbreviation: "2Мак", chapters: 15),
        BibleBook(key: "3ma", name: "3-я Маккавейская", abbreviation: "3Мак", chapters: 7),
        BibleBook(key: "1es", name: "2-я Ездры", abbreviation: "2Езд", chapters: 9),
        BibleBook(key: "3es", name: "3-я Ездры", abbreviation: "3Езд", chapters: 16),
    ]
}

// MARK: - Placeholder ReaderView

struct ReaderView: View {
    let bookKey: String
    let chapter: Int
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    private let theme = OrthodoxTheme.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Глава \(chapter)")
                    .font(.custom("CormorantGaramond-SemiBold", size: 24))
                    .foregroundColor(theme.text)
                    .padding(.top, 20)
                
                Text("Текст из SQLite базы данных (Синодальный перевод)\nбудет загружаться из trevarj/rsb.")
                    .font(.custom("CormorantGaramond-Regular", size: appState.fontSize))
                    .foregroundColor(theme.muted)
                    .lineSpacing(6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .background(Color(hex: "FAF8F5"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(bookKey.uppercased())
                    .font(.custom("CormorantGaramond-Medium", size: 16))
                    .foregroundColor(theme.text)
            }
        }
    }
}

#Preview {
    BibleView()
        .environmentObject(AppState())
        .environmentObject(TabNavigationState(tab: .bible))
}
