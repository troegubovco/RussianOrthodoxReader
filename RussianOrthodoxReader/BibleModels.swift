import Foundation

// MARK: - Bible Structure

enum Testament: String, CaseIterable, Identifiable {
    case old = "Ветхий Завет"
    case new = "Новый Завет"
    var id: String { rawValue }
}

struct BibleBook: Identifiable, Hashable {
    let id: String
    let name: String
    let abbreviation: String
    let testament: Testament
    let chapterCount: Int
}

struct BibleChapter: Identifiable {
    let id: String          // e.g. "mat-5"
    let bookId: String
    let bookName: String
    let chapter: Int
    let verses: [BibleVerse]
}

struct BibleVerse: Identifiable {
    let id: Int             // verse number
    let number: Int
    let synodal: String
    let modern: String
}

enum TranslationMode: String, CaseIterable, Identifiable {
    case synodal = "Синодальный"
    case modern = "Современный"
    case comparison = "Сравнение"
    var id: String { rawValue }
}

// MARK: - Bible Data Provider

/// In production, this would load from a local SQLite/JSON database.
/// For now, it provides sample data for the prototype.
struct BibleDataProvider {
    
    static let books: [BibleBook] = [
        // Ветхий Завет
        BibleBook(id: "gen", name: "Бытие", abbreviation: "Быт", testament: .old, chapterCount: 50),
        BibleBook(id: "exo", name: "Исход", abbreviation: "Исх", testament: .old, chapterCount: 40),
        BibleBook(id: "lev", name: "Левит", abbreviation: "Лев", testament: .old, chapterCount: 27),
        BibleBook(id: "num", name: "Числа", abbreviation: "Чис", testament: .old, chapterCount: 36),
        BibleBook(id: "deu", name: "Второзаконие", abbreviation: "Втор", testament: .old, chapterCount: 34),
        BibleBook(id: "jos", name: "Иисус Навин", abbreviation: "Нав", testament: .old, chapterCount: 24),
        BibleBook(id: "jdg", name: "Книга Судей", abbreviation: "Суд", testament: .old, chapterCount: 21),
        BibleBook(id: "rut", name: "Руфь", abbreviation: "Руф", testament: .old, chapterCount: 4),
        BibleBook(id: "1sa", name: "1-я Царств", abbreviation: "1Цар", testament: .old, chapterCount: 31),
        BibleBook(id: "2sa", name: "2-я Царств", abbreviation: "2Цар", testament: .old, chapterCount: 24),
        BibleBook(id: "1ki", name: "3-я Царств", abbreviation: "3Цар", testament: .old, chapterCount: 22),
        BibleBook(id: "2ki", name: "4-я Царств", abbreviation: "4Цар", testament: .old, chapterCount: 25),
        BibleBook(id: "job", name: "Иов", abbreviation: "Иов", testament: .old, chapterCount: 42),
        BibleBook(id: "psa", name: "Псалтирь", abbreviation: "Пс", testament: .old, chapterCount: 150),
        BibleBook(id: "pro", name: "Притчи", abbreviation: "Притч", testament: .old, chapterCount: 31),
        BibleBook(id: "ecc", name: "Екклесиаст", abbreviation: "Еккл", testament: .old, chapterCount: 12),
        BibleBook(id: "sng", name: "Песнь Песней", abbreviation: "Песн", testament: .old, chapterCount: 8),
        BibleBook(id: "isa", name: "Исаия", abbreviation: "Ис", testament: .old, chapterCount: 66),
        BibleBook(id: "jer", name: "Иеремия", abbreviation: "Иер", testament: .old, chapterCount: 52),
        BibleBook(id: "eze", name: "Иезекииль", abbreviation: "Иез", testament: .old, chapterCount: 48),
        BibleBook(id: "dan", name: "Даниил", abbreviation: "Дан", testament: .old, chapterCount: 12),
        
        // Новый Завет
        BibleBook(id: "mat", name: "От Матфея", abbreviation: "Мф", testament: .new, chapterCount: 28),
        BibleBook(id: "mar", name: "От Марка", abbreviation: "Мк", testament: .new, chapterCount: 16),
        BibleBook(id: "luk", name: "От Луки", abbreviation: "Лк", testament: .new, chapterCount: 24),
        BibleBook(id: "joh", name: "От Иоанна", abbreviation: "Ин", testament: .new, chapterCount: 21),
        BibleBook(id: "act", name: "Деяния", abbreviation: "Деян", testament: .new, chapterCount: 28),
        BibleBook(id: "rom", name: "К Римлянам", abbreviation: "Рим", testament: .new, chapterCount: 16),
        BibleBook(id: "1co", name: "1-е Коринфянам", abbreviation: "1Кор", testament: .new, chapterCount: 16),
        BibleBook(id: "2co", name: "2-е Коринфянам", abbreviation: "2Кор", testament: .new, chapterCount: 13),
        BibleBook(id: "gal", name: "К Галатам", abbreviation: "Гал", testament: .new, chapterCount: 6),
        BibleBook(id: "eph", name: "К Ефесянам", abbreviation: "Еф", testament: .new, chapterCount: 6),
        BibleBook(id: "phi", name: "К Филиппийцам", abbreviation: "Флп", testament: .new, chapterCount: 4),
        BibleBook(id: "col", name: "К Колоссянам", abbreviation: "Кол", testament: .new, chapterCount: 4),
        BibleBook(id: "1th", name: "1-е Фессалоникийцам", abbreviation: "1Фес", testament: .new, chapterCount: 5),
        BibleBook(id: "2th", name: "2-е Фессалоникийцам", abbreviation: "2Фес", testament: .new, chapterCount: 3),
        BibleBook(id: "1ti", name: "1-е Тимофею", abbreviation: "1Тим", testament: .new, chapterCount: 6),
        BibleBook(id: "2ti", name: "2-е Тимофею", abbreviation: "2Тим", testament: .new, chapterCount: 4),
        BibleBook(id: "tit", name: "К Титу", abbreviation: "Тит", testament: .new, chapterCount: 3),
        BibleBook(id: "phm", name: "К Филимону", abbreviation: "Флм", testament: .new, chapterCount: 1),
        BibleBook(id: "heb", name: "К Евреям", abbreviation: "Евр", testament: .new, chapterCount: 13),
        BibleBook(id: "jas", name: "Иакова", abbreviation: "Иак", testament: .new, chapterCount: 5),
        BibleBook(id: "1pe", name: "1-е Петра", abbreviation: "1Пет", testament: .new, chapterCount: 5),
        BibleBook(id: "2pe", name: "2-е Петра", abbreviation: "2Пет", testament: .new, chapterCount: 3),
        BibleBook(id: "1jo", name: "1-е Иоанна", abbreviation: "1Ин", testament: .new, chapterCount: 5),
        BibleBook(id: "2jo", name: "2-е Иоанна", abbreviation: "2Ин", testament: .new, chapterCount: 1),
        BibleBook(id: "3jo", name: "3-е Иоанна", abbreviation: "3Ин", testament: .new, chapterCount: 1),
        BibleBook(id: "jud", name: "Иуды", abbreviation: "Иуд", testament: .new, chapterCount: 1),
        BibleBook(id: "rev", name: "Откровение", abbreviation: "Откр", testament: .new, chapterCount: 22),
    ]
    
    static func books(for testament: Testament) -> [BibleBook] {
        books.filter { $0.testament == testament }
    }
    
    /// Returns a sample chapter. In production, load from local DB.
    static func chapter(bookId: String, chapter: Int) -> BibleChapter? {
        let key = "\(bookId)-\(chapter)"
        return sampleChapters[key]
    }
    
    static func hasChapter(bookId: String) -> Bool {
        sampleChapters.keys.contains(where: { $0.hasPrefix(bookId) })
    }
    
    static func firstAvailableChapter(bookId: String) -> String? {
        sampleChapters.keys.first(where: { $0.hasPrefix(bookId) })
    }
    
    // MARK: - Sample Data
    
    private static let sampleChapters: [String: BibleChapter] = [
        "mat-5": BibleChapter(id: "mat-5", bookId: "mat", bookName: "От Матфея", chapter: 5, verses: [
            BibleVerse(id: 1, number: 1,
                synodal: "Увидев народ, Он взошел на гору; и, когда сел, приступили к Нему ученики Его.",
                modern: "Увидев толпы народа, Иисус поднялся на гору и сел. Его ученики подошли к Нему."),
            BibleVerse(id: 2, number: 2,
                synodal: "И Он, отверзши уста Свои, учил их, говоря:",
                modern: "И Он начал их учить:"),
            BibleVerse(id: 3, number: 3,
                synodal: "Блаженны нищие духом, ибо их есть Царство Небесное.",
                modern: "Блаженны нищие духом — ибо им принадлежит Царство Небесное."),
            BibleVerse(id: 4, number: 4,
                synodal: "Блаженны плачущие, ибо они утешатся.",
                modern: "Блаженны скорбящие — ибо они будут утешены."),
            BibleVerse(id: 5, number: 5,
                synodal: "Блаженны кроткие, ибо они наследуют землю.",
                modern: "Блаженны кроткие — ибо они наследуют землю."),
            BibleVerse(id: 6, number: 6,
                synodal: "Блаженны алчущие и жаждущие правды, ибо они насытятся.",
                modern: "Блаженны те, кто жаждет праведности, — ибо они насытятся."),
            BibleVerse(id: 7, number: 7,
                synodal: "Блаженны милостивые, ибо они помилованы будут.",
                modern: "Блаженны милосердные — ибо они будут помилованы."),
            BibleVerse(id: 8, number: 8,
                synodal: "Блаженны чистые сердцем, ибо они Бога узрят.",
                modern: "Блаженны чистые сердцем — ибо они увидят Бога."),
            BibleVerse(id: 9, number: 9,
                synodal: "Блаженны миротворцы, ибо они будут наречены сынами Божиими.",
                modern: "Блаженны миротворцы — ибо они будут названы сынами Божьими."),
            BibleVerse(id: 10, number: 10,
                synodal: "Блаженны изгнанные за правду, ибо их есть Царство Небесное.",
                modern: "Блаженны гонимые за праведность — ибо им принадлежит Царство Небесное."),
            BibleVerse(id: 11, number: 11,
                synodal: "Блаженны вы, когда будут поносить вас и гнать и всячески неправедно злословить за Меня.",
                modern: "Блаженны вы, когда вас оскорбляют, преследуют и возводят на вас всякую ложь из-за Меня."),
            BibleVerse(id: 12, number: 12,
                synodal: "Радуйтесь и веселитесь, ибо велика ваша награда на небесах: так гнали и пророков, бывших прежде вас.",
                modern: "Радуйтесь и ликуйте, потому что велика ваша награда на небесах! Ведь точно так же преследовали пророков, бывших до вас."),
            BibleVerse(id: 13, number: 13,
                synodal: "Вы — соль земли. Если же соль потеряет силу, то чем сделаешь ее соленою? Она уже ни к чему негодна, как разве выбросить ее вон на попрание людям.",
                modern: "Вы — соль земли. Но если соль перестанет быть солёной, чем вы сделаете её вновь солёной? Она уже ни на что не годна — только выбросить на дорогу, под ноги людям."),
            BibleVerse(id: 14, number: 14,
                synodal: "Вы — свет мира. Не может укрыться город, стоящий на верху горы.",
                modern: "Вы — свет мира. Город, стоящий на горе, не может быть скрыт."),
            BibleVerse(id: 15, number: 15,
                synodal: "И, зажегши свечу, не ставят ее под сосудом, но на подсвечнике, и светит всем в доме.",
                modern: "Зажжённый светильник не ставят под горшок — его ставят на подставку, и он светит всем в доме."),
            BibleVerse(id: 16, number: 16,
                synodal: "Так да светит свет ваш пред людьми, чтобы они видели ваши добрые дела и прославляли Отца вашего Небесного.",
                modern: "Пусть так же светит и ваш свет перед людьми, чтобы они видели ваши добрые дела и славили вашего Небесного Отца."),
        ]),
        
        "joh-1": BibleChapter(id: "joh-1", bookId: "joh", bookName: "От Иоанна", chapter: 1, verses: [
            BibleVerse(id: 1, number: 1, synodal: "В начале было Слово, и Слово было у Бога, и Слово было Бог.", modern: "В начале было Слово. Слово было у Бога, и Слово было Бог."),
            BibleVerse(id: 2, number: 2, synodal: "Оно было в начале у Бога.", modern: "Оно было в начале у Бога."),
            BibleVerse(id: 3, number: 3, synodal: "Все чрез Него начало быть, и без Него ничто не начало быть, что начало быть.", modern: "Через Него было сотворено всё, и без Него не было сотворено ничего из того, что существует."),
            BibleVerse(id: 4, number: 4, synodal: "В Нем была жизнь, и жизнь была свет человеков.", modern: "В Нём была жизнь, и жизнь была светом для людей."),
            BibleVerse(id: 5, number: 5, synodal: "И свет во тьме светит, и тьма не объяла его.", modern: "Свет светит во тьме, и тьма не поглотила его."),
            BibleVerse(id: 6, number: 6, synodal: "Был человек, посланный от Бога; имя ему Иоанн.", modern: "Был человек, посланный Богом; его звали Иоанн."),
            BibleVerse(id: 7, number: 7, synodal: "Он пришел для свидетельства, чтобы свидетельствовать о Свете, дабы все уверовали чрез него.", modern: "Он пришёл как свидетель — свидетельствовать о Свете, чтобы через него все поверили."),
            BibleVerse(id: 8, number: 8, synodal: "Он не был свет, но был послан, чтобы свидетельствовать о Свете.", modern: "Он сам не был Светом, а лишь свидетелем Света."),
            BibleVerse(id: 9, number: 9, synodal: "Был Свет истинный, Который просвещает всякого человека, приходящего в мир.", modern: "Был Свет истинный, Который просвещает каждого человека, — Он шёл в мир."),
            BibleVerse(id: 10, number: 10, synodal: "В мире был, и мир чрез Него начал быть, и мир Его не познал.", modern: "Он был в мире, и мир через Него был сотворён, но мир Его не узнал."),
        ]),
        
        "psa-50": BibleChapter(id: "psa-50", bookId: "psa", bookName: "Псалтирь", chapter: 50, verses: [
            BibleVerse(id: 1, number: 1, synodal: "Начальнику хора. Псалом Давида,", modern: "Руководителю хора. Псалом Давида."),
            BibleVerse(id: 2, number: 2, synodal: "когда приходил к нему пророк Нафан, после того, как Давид вошел к Вирсавии.", modern: "Когда пришёл к нему пророк Нафан — после того, как Давид был с Вирсавией."),
            BibleVerse(id: 3, number: 3, synodal: "Помилуй меня, Боже, по великой милости Твоей, и по множеству щедрот Твоих изгладь беззакония мои.", modern: "Помилуй меня, Боже, по великой милости Твоей. По безмерному милосердию Твоему сотри мои беззакония."),
            BibleVerse(id: 4, number: 4, synodal: "Многократно омой меня от беззакония моего, и от греха моего очисти меня,", modern: "Отмой меня от моего беззакония и очисти от моего греха."),
            BibleVerse(id: 5, number: 5, synodal: "ибо беззакония мои я сознаю, и грех мой всегда предо мною.", modern: "Ибо я знаю свои преступления, и мой грех всегда передо мной."),
            BibleVerse(id: 6, number: 6, synodal: "Тебе, Тебе единому согрешил я и лукавое пред очами Твоими сделал, так что Ты праведен в приговоре Твоем и чист в суде Твоем.", modern: "Против Тебя, Тебя одного я согрешил и сделал злое пред Твоими очами. Ты прав в Своём приговоре и справедлив в Своём суде."),
            BibleVerse(id: 7, number: 7, synodal: "Вот, я в беззаконии зачат, и во грехе родила меня мать моя.", modern: "Я был грешен от рождения, грешен с того мига, как мать зачала меня."),
            BibleVerse(id: 8, number: 8, synodal: "Вот, Ты возлюбил истину в сердце и внутрь меня явил мне мудрость.", modern: "Ты желаешь верности в сердце и в глубине души учишь меня мудрости."),
            BibleVerse(id: 9, number: 9, synodal: "Окропи меня иссопом, и буду чист; омой меня, и буду белее снега.", modern: "Окропи меня иссопом — и буду чист. Омой меня — и стану белее снега."),
            BibleVerse(id: 10, number: 10, synodal: "Дай мне услышать радость и веселие, и возрадуются кости, Тобою сокрушенные.", modern: "Дай мне снова услышать радость и веселье — и возрадуются кости, которые Ты сокрушил."),
        ]),
    ]
}
