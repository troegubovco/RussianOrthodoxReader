import Foundation
import SQLite3

struct DictionaryEntry: Identifiable, Hashable {
    let id: String      // = word
    let word: String
    let definition: String
    let source: String
}

final class DictionaryRepository {
    static let shared = DictionaryRepository()

    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        openDatabase()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Returns entries whose word starts with the query (case-insensitive).
    /// Also resolves inflected forms via the conjugation map.
    /// Falls back to the built-in dictionary if no SQLite database is bundled.
    func search(query: String) -> [DictionaryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if db != nil {
            // Direct prefix search
            var results = sqliteSearch(query: trimmed)

            // Also try conjugation lookup: resolve inflected form → lemma
            let lemmas = lookupLemmas(for: trimmed)
            for lemma in lemmas {
                if let entry = sqliteExact(word: lemma),
                   !results.contains(where: { $0.word.lowercased() == entry.word.lowercased() }) {
                    results.insert(entry, at: 0)
                }
            }

            return results
        }
        return fallbackSearch(query: trimmed)
    }

    /// Look up an exact word (case-insensitive). Tries conjugation map,
    /// then prefix match if no exact hit.
    func lookup(word: String) -> DictionaryEntry? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if db != nil {
            // Try exact match first
            if let entry = sqliteExact(word: trimmed) {
                return entry
            }
            // Try conjugation map: inflected form → lemma → entry
            let lemmas = lookupLemmas(for: trimmed)
            for lemma in lemmas {
                if let entry = sqliteExact(word: lemma) {
                    return entry
                }
            }
            // Fall back to prefix search
            return sqliteSearch(query: trimmed).first
        }
        let lower = trimmed.lowercased()
        return Self.fallback.first(where: { $0.word.lowercased() == lower })
            ?? fallbackSearch(query: trimmed).first
    }

    // MARK: - SQLite (rus_dictionary.sqlite)

    private func openDatabase() {
        let candidates = [
            Bundle.main.url(forResource: "rus_dictionary", withExtension: "sqlite",
                            subdirectory: "Bible"),
            Bundle.main.url(forResource: "rus_dictionary", withExtension: "sqlite"),
            Bundle.main.url(forResource: "rus_dictionary", withExtension: "sqlite",
                            subdirectory: "Resources/Bible")
        ]
        guard let url = candidates.compactMap({ $0 }).first else { return }
        var connection: OpaquePointer?
        if sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = connection
        } else {
            if let connection { sqlite3_close(connection) }
        }
    }

    private func sqliteSearch(query: String) -> [DictionaryEntry] {
        guard let db else { return [] }
        let sql = """
        SELECT word, definition, source
        FROM entries
        WHERE word LIKE ? ESCAPE '\\'
        ORDER BY length(word) ASC, word ASC
        LIMIT 40
        """
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let pattern = query.replacingOccurrences(of: "%", with: "\\%") + "%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        var results: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let wPtr = sqlite3_column_text(stmt, 0),
                let dPtr = sqlite3_column_text(stmt, 1)
            else { continue }
            let word = String(cString: wPtr)
            let definition = String(cString: dPtr)
            let source = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Нюстрем"
            results.append(DictionaryEntry(id: word, word: word, definition: definition, source: source))
        }
        return results
    }

    private func sqliteExact(word: String) -> DictionaryEntry? {
        guard let db else { return nil }
        let sql = "SELECT word, definition, source FROM entries WHERE lower(word) = lower(?) LIMIT 1"
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (word as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let wPtr = sqlite3_column_text(stmt, 0),
              let dPtr = sqlite3_column_text(stmt, 1) else { return nil }
        let w = String(cString: wPtr)
        let d = String(cString: dPtr)
        let src = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Нюстрем"
        return DictionaryEntry(id: w, word: w, definition: d, source: src)
    }

    // MARK: - Conjugation map

    /// Looks up the lemma(s) for an inflected form in the conjugations table.
    private func lookupLemmas(for form: String) -> [String] {
        guard let db else { return [] }
        let sql = "SELECT DISTINCT lemma FROM conjugations WHERE form = ? LIMIT 5"
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let lower = form.lowercased()
        sqlite3_bind_text(stmt, 1, (lower as NSString).utf8String, -1, nil)
        var lemmas: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0) else { continue }
            lemmas.append(String(cString: ptr))
        }
        return lemmas
    }

    // MARK: - Fallback (inline Nyström entries)

    private func fallbackSearch(query: String) -> [DictionaryEntry] {
        let lower = query.lowercased()
        return Self.fallback.filter { $0.word.lowercased().hasPrefix(lower) }
    }

    // MARK: - Built-in Nyström Biblical Dictionary (public domain, 1874)
    // Source: Нюстрем Э. Библейский словарь. — СПб.: Библия для всех, 2001.
    // These entries cover the most frequently encountered terms in the Russian Synodal Bible.

    static let fallback: [DictionaryEntry] = [

        // ─── Библейские персонажи ────────────────────────────────────────────

        DictionaryEntry(id: "авраам", word: "Авраам", definition: "«Отец множества» (евр.). Праотец еврейского народа, жившего около 2000 г. до Р.Х. Призван Богом из Ура Халдейского. Получил обетование о потомстве и Земле Обетованной. Отец Исаака.", source: "Нюстрем"),

        DictionaryEntry(id: "адам", word: "Адам", definition: "«Человек», «земной» (евр.). Первый человек, созданный Богом из праха земного. Муж Евы. Жил в Едемском саду до грехопадения.", source: "Нюстрем"),

        DictionaryEntry(id: "ева", word: "Ева", definition: "«Жизнь» (евр.). Первая женщина, созданная Богом из ребра Адама. Мать всех живущих.", source: "Нюстрем"),

        DictionaryEntry(id: "моисей", word: "Моисей", definition: "Пророк и законодатель. Вывел израильтян из египетского рабства. На горе Синай получил от Бога Десять заповедей. Написал Пятикнижие.", source: "Нюстрем"),

        DictionaryEntry(id: "давид", word: "Давид", definition: "Второй царь Израиля (ок. 1010–970 до Р.Х.). Псалмопевец. Победил Голиафа. Родоначальник царского рода, от которого произошёл по плоти Иисус Христос.", source: "Нюстрем"),

        DictionaryEntry(id: "соломон", word: "Соломон", definition: "Сын Давида, третий царь Израиля. Построил Иерусалимский храм. Прославился исключительной мудростью. Написал Притчи, Екклесиаст и Песнь Песней.", source: "Нюстрем"),

        DictionaryEntry(id: "илия", word: "Илия", definition: "Великий пророк IX в. до Р.Х. Ревностный защитник истинного богопочитания. Был взят живым на небо на огненной колеснице. Прообраз Иоанна Предтечи.", source: "Нюстрем"),

        DictionaryEntry(id: "иоанн предтеча", word: "Иоанн Предтеча", definition: "Пророк, предшествовавший Иисусу Христу. Сын священника Захарии и Елисаветы. Крестил в Иордане покаянным крещением. Обезглавлен по приказу Ирода.", source: "Нюстрем"),

        DictionaryEntry(id: "пётр", word: "Пётр", definition: "Апостол, первенствующий среди двенадцати. Рыбак Симон, сын Ионы, переименованный Христом в Кифу (Пётр — «камень»). Глава первых христианских общин. Пострадал в Риме.", source: "Нюстрем"),

        DictionaryEntry(id: "павел", word: "Павел", definition: "«Апостол язычников». Прежде — Савл из Тарса, фарисей и гонитель христиан. После явления Христа на пути в Дамаск обратился. Совершил три миссионерских путешествия.", source: "Нюстрем"),

        DictionaryEntry(id: "иуда", word: "Иуда", definition: "Иуда Искариот — один из двенадцати апостолов, хранитель денежного ящика. Предал Иисуса первосвященникам за тридцать сребреников. Впоследствии раскаялся и удавился.", source: "Нюстрем"),

        DictionaryEntry(id: "мария", word: "Мария", definition: "Пресвятая Дева, Матерь Иисуса Христа. Дочь Иоакима и Анны. От неё воплотился Сын Божий. Почитается Богородицей во всех христианских Церквях.", source: "Нюстрем"),

        DictionaryEntry(id: "иосиф", word: "Иосиф", definition: "1) Иосиф — сын Иакова (патриарх), проданный братьями в Египет. Стал главным управителем Египта и спас семью от голода. 2) Иосиф Обручник — муж Марии, хранитель Богомладенца.", source: "Нюстрем"),

        DictionaryEntry(id: "иоанн", word: "Иоанн", definition: "Апостол и евангелист, «возлюбленный ученик» Христа. Сын Зеведея, брат апостола Иакова. Написал четвёртое Евангелие, три послания и Откровение. Дожил до глубокой старости в Ефесе.", source: "Нюстрем"),

        DictionaryEntry(id: "исайя", word: "Исайя", definition: "Величайший из пророков. Жил в Иерусалиме в VIII в. до Р.Х. Особенно ярко пророчествовал о пришествии Мессии и страданиях Христовых (Ис. 53). Книга Исайи — 66 глав.", source: "Нюстрем"),

        DictionaryEntry(id: "иеремия", word: "Иеремия", definition: "Пророк VII–VI вв. до Р.Х. «Плачущий пророк». Пережил падение Иерусалима и вавилонский плен. Написал Книгу Иеремии и Плач Иеремии.", source: "Нюстрем"),

        DictionaryEntry(id: "иов", word: "Иов", definition: "Праведник, испытанный тяжёлыми страданиями. Несмотря на потери и болезнь сохранил веру в Бога. Господь восстановил его благополучие. Его история изложена в Книге Иова.", source: "Нюстрем"),

        DictionaryEntry(id: "ной", word: "Ной", definition: "Праведник, спасённый от всемирного потопа. По повелению Бога построил ковчег, в котором спаслись он, его семья и по паре каждого вида животных. Прародитель послепотопного человечества.", source: "Нюстрем"),

        DictionaryEntry(id: "исаак", word: "Исаак", definition: "Сын Авраама и Сарры, рождённый по обетованию Бога в глубокой старости родителей. Отец Иакова и Исава. Прообраз Христа: был принесён в жертву и «воскрес».", source: "Нюстрем"),

        DictionaryEntry(id: "иаков", word: "Иаков", definition: "Сын Исаака, внук Авраама. Переименован Богом в Израиля («борющийся с Богом»). Отец двенадцати патриархов — родоначальников двенадцати колен Израилевых.", source: "Нюстрем"),

        // ─── Библейские места ────────────────────────────────────────────────

        DictionaryEntry(id: "иерусалим", word: "Иерусалим", definition: "Священный город Израиля и всего христианского мира. Место Иерусалимского храма, Голгофы и Гроба Господня. Завоёван Давидом около 1000 г. до Р.Х.", source: "Нюстрем"),

        DictionaryEntry(id: "вифлеем", word: "Вифлеем", definition: "«Дом хлеба» (евр.). Город в Иудее, в 9 км от Иерусалима. Родина царя Давида. Место рождения Иисуса Христа (Мих. 5:2; Мф. 2:1).", source: "Нюстрем"),

        DictionaryEntry(id: "назарет", word: "Назарет", definition: "Город в Галилее, где Иисус провёл детство и юность. Поэтому Его часто называли «Иисус Назарянин». Жители отвергли Его проповедь.", source: "Нюстрем"),

        DictionaryEntry(id: "иордан", word: "Иордан", definition: "Главная река Израиля. Берёт начало у горы Ермон, впадает в Мёртвое море. В Иордане Иоанн Предтеча крестил народ и самого Иисуса Христа.", source: "Нюстрем"),

        DictionaryEntry(id: "иудея", word: "Иудея", definition: "Историческая область в южной части Израиля. Главный город — Иерусалим. Колыбель иудейской монархии и центр религиозной жизни еврейского народа.", source: "Нюстрем"),

        DictionaryEntry(id: "галилея", word: "Галилея", definition: "Северная область Израиля. Большинство апостолов происходили отсюда. Здесь Иисус провёл большую часть Своего служения и совершил многие чудеса.", source: "Нюстрем"),

        DictionaryEntry(id: "самария", word: "Самария", definition: "Область между Иудеей и Галилеей. Самаряне — потомки смешанного населения после ассирийского завоевания. Иудеи сторонились самарян, хотя Христос общался с ними.", source: "Нюстрем"),

        DictionaryEntry(id: "синай", word: "Синай", definition: "Гора на Синайском полуострове, также называемая Хорив. На этой горе Бог явился Моисею в горящем кусте и дал ему Десять заповедей (Исх. 3; 19–20).", source: "Нюстрем"),

        DictionaryEntry(id: "египет", word: "Египет", definition: "Страна в Северной Африке. Место 430-летнего рабства Израиля. Иосиф и позднее Моисей жили в Египте. Исход из Египта стал главным событием ветхозаветной истории.", source: "Нюстрем"),

        DictionaryEntry(id: "вавилон", word: "Вавилон", definition: "Столица Вавилонского царства в Месопотамии. Навуходоносор разрушил Иерусалим в 586 г. до Р.Х. и увёл евреев в вавилонский плен. В Откровении Вавилон — символ безбожного мира.", source: "Нюстрем"),

        DictionaryEntry(id: "голгофа", word: "Голгофа", definition: "«Лобное место», «место черепа» (арам.). Холм близ Иерусалима, где был распят Иисус Христос. Ныне находится в Храме Гроба Господня.", source: "Нюстрем"),

        DictionaryEntry(id: "гефсимания", word: "Гефсимания", definition: "«Масличный пресс» (евр.). Сад у подножия Елеонской горы. Здесь Иисус молился в ночь перед распятием: «Не Моя воля, но Твоя да будет» (Лк. 22:42).", source: "Нюстрем"),

        DictionaryEntry(id: "ермон", word: "Ермон", definition: "Высочайшая гора Израиля (2814 м) на севере страны. На ней, по преданию, произошло Преображение Господне. Вечные снега на вершине.", source: "Нюстрем"),

        // ─── Богослужение и храм ─────────────────────────────────────────────

        DictionaryEntry(id: "скиния", word: "Скиния", definition: "Переносной храм — священный шатёр, построенный по указанию Бога во время странствия израильтян в пустыне. Включала святое и Святое святых, где находился ковчег завета.", source: "Нюстрем"),

        DictionaryEntry(id: "ковчег завета", word: "Ковчег завета", definition: "Священный ящик из акациевого дерева, обитый золотом. Хранил скрижали завета (Десять заповедей), жезл Аарона и манну. Символ присутствия Бога среди народа.", source: "Нюстрем"),

        DictionaryEntry(id: "храм", word: "Храм", definition: "Иерусалимский храм — главное святилище еврейского народа. Первый (Соломонов) разрушен вавилонянами в 586 г. до Р.Х. Второй — разрушен римлянами в 70 г. по Р.Х.", source: "Нюстрем"),

        DictionaryEntry(id: "синагога", word: "Синагога", definition: "«Собрание» (греч.). Место молитвенного собрания, чтения Священного Писания и его толкования у евреев. Возникла в вавилонский период как замена храму.", source: "Нюстрем"),

        DictionaryEntry(id: "первосвященник", word: "Первосвященник", definition: "Главный священник, возглавлявший иудейское священство. Один раз в год — в День очищения — входил в Святое святых. Образ небесного первосвященника — Иисуса Христа (Евр. 4:14).", source: "Нюстрем"),

        DictionaryEntry(id: "жертвенник", word: "Жертвенник", definition: "Алтарь для принесения жертв Богу. В скинии и храме был жертвенник всесожжений (во дворе) и жертвенник курений (в святом месте). Образ молитвы, возносящейся к Богу.", source: "Нюстрем"),

        DictionaryEntry(id: "левит", word: "Левит", definition: "Член колена Левия. Помощник священников при богослужении. Отвечал за перенос скинии, пение и охрану храма. Не получил земельного удела в Израиле.", source: "Нюстрем"),

        DictionaryEntry(id: "священник", word: "Священник", definition: "Служитель святилища из потомков Аарона. Совершал жертвоприношения, воскурял фимиам, благословлял народ. В Новом Завете священство Христово и церковное священство.", source: "Нюстрем"),

        // ─── Религиозные партии и чины ───────────────────────────────────────

        DictionaryEntry(id: "фарисей", word: "Фарисей", definition: "«Отделённый» (евр.). Член иудейской религиозной партии, строго соблюдавшей Закон и устные предания. Нередко уклонялись в лицемерие. Неоднократно вступали в споры с Иисусом.", source: "Нюстрем"),

        DictionaryEntry(id: "саддукей", word: "Саддукей", definition: "Представитель иудейской аристократической партии. Отрицали воскресение мёртвых, бессмертие души и существование ангелов. Опирались только на Пятикнижие Моисея.", source: "Нюстрем"),

        DictionaryEntry(id: "книжник", word: "Книжник", definition: "Переписчик и толкователь Закона Моисеева. Законоучитель в иудейском обществе. Вместе с фарисеями и первосвященниками противостояли Христу.", source: "Нюстрем"),

        DictionaryEntry(id: "мытарь", word: "Мытарь", definition: "Сборщик налогов на службе римского правительства. Евреи презирали мытарей как предателей и нечестивцев. Иисус общался с ними, в том числе призвал Матфея и Закхея.", source: "Нюстрем"),

        // ─── Богословские понятия ────────────────────────────────────────────

        DictionaryEntry(id: "апостол", word: "Апостол", definition: "«Посланник» (греч.). Двенадцать ближайших учеников Иисуса Христа, избранных и посланных на проповедь Евангелия. В широком смысле — Павел и другие миссионеры.", source: "Нюстрем"),

        DictionaryEntry(id: "евангелие", word: "Евангелие", definition: "«Благая весть» (греч.). Весть о пришествии Царства Бога и спасении людей через Иисуса Христа. Также — одна из четырёх книг: Евангелие от Матфея, Марка, Луки, Иоанна.", source: "Нюстрем"),

        DictionaryEntry(id: "мессия", word: "Мессия", definition: "«Помазанник» (евр.); по-гречески — Христос. Ожидаемый Спаситель, предсказанный ветхозаветными пророками. Христиане исповедуют, что Иисус из Назарета — исполнение мессианских пророчеств.", source: "Нюстрем"),

        DictionaryEntry(id: "завет", word: "Завет", definition: "Договор-союз между Богом и человеком. Ветхий Завет — с народом Израиля через Моисея. Новый Завет — через Иисуса Христа со всем человечеством (Лк. 22:20; Евр. 8:6–13).", source: "Нюстрем"),

        DictionaryEntry(id: "заповедь", word: "Заповедь", definition: "Повеление Бога, обязательное для исполнения. Главные — Десять заповедей (Исх. 20). Иисус суммировал их в двух: любить Бога и ближнего (Мф. 22:37–40).", source: "Нюстрем"),

        DictionaryEntry(id: "пасха", word: "Пасха", definition: "«Прохождение мимо» (евр.). Главный ветхозаветный праздник в память Исхода из Египта. В христианстве — праздник Воскресения Христова как нашей Пасхи (1 Кор. 5:7).", source: "Нюстрем"),

        DictionaryEntry(id: "суббота", word: "Суббота", definition: "Седьмой день недели — день покоя, заповеданный Богом при сотворении мира (Быт. 2:3). Для евреев — священный день молитвы и отдыха. Христиане чтут воскресенье как день Воскресения.", source: "Нюстрем"),

        DictionaryEntry(id: "крещение", word: "Крещение", definition: "Погружение в воду или обливание как знак очищения и рождения свыше. Иоанн крестил покаянным крещением. Христос установил крещение «во имя Отца и Сына и Святого Духа» (Мф. 28:19).", source: "Нюстрем"),

        DictionaryEntry(id: "воскресение", word: "Воскресение", definition: "Возвращение к жизни после смерти. Воскресение Христово на третий день — основа христианской веры (1 Кор. 15:14). Обещано всеобщее воскресение мёртвых в конце времён.", source: "Нюстрем"),

        DictionaryEntry(id: "благодать", word: "Благодать", definition: "Особая Божья сила, незаслуженная милость Бога, действующая в человеке для его спасения и освящения. «Благодатью вы спасены через веру» (Еф. 2:8).", source: "Нюстрем"),

        DictionaryEntry(id: "искупление", word: "Искупление", definition: "Освобождение человечества от власти греха и смерти через крестную жертву Иисуса Христа. Образ взят из практики выкупа рабов на свободу.", source: "Нюстрем"),

        DictionaryEntry(id: "пророк", word: "Пророк", definition: "Человек, говорящий по вдохновению Бога и возвещающий Его волю. Великие пророки В.З.: Исаия, Иеремия, Иезекииль, Даниил. Иоанн Предтеча — последний пророк В.З.", source: "Нюстрем"),

        DictionaryEntry(id: "праведник", word: "Праведник", definition: "Человек, живущий по заповедям Бога и угодный Ему. В Новом Завете праведность достигается не делами Закона, но верой в Иисуса Христа (Рим. 3:22).", source: "Нюстрем"),

        // ─── Денежные единицы и меры ─────────────────────────────────────────

        DictionaryEntry(id: "талант", word: "Талант", definition: "Единица веса и стоимости. 1 серебряный талант = 6 000 денариев = 20 лет труда работника. Упоминается в притче о талантах (Мф. 25:14–30) и о немилосердном заимодавце.", source: "Нюстрем"),

        DictionaryEntry(id: "мина", word: "Мина", definition: "Денежная единица. 1 мина = 100 денариев. Упоминается в притче о минах (Лк. 19:11–27). Составляла 1/60 таланта.", source: "Нюстрем"),

        DictionaryEntry(id: "динарий", word: "Динарий", definition: "Римская серебряная монета. Равнялась дневному заработку рабочего (Мф. 20:2). Упоминается в притче о виноградарях и при вопросе о подати кесарю (Мф. 22:19).", source: "Нюстрем"),

        DictionaryEntry(id: "сребреник", word: "Сребреник", definition: "Серебряная монета (шекель). За тридцать сребреников Иуда предал Иисуса первосвященникам (Мф. 26:15), что исполнило пророчество Захарии (Зах. 11:12–13).", source: "Нюстрем"),

        DictionaryEntry(id: "лепта", word: "Лепта", definition: "Наименьшая медная монета у иудеев. 2 лепты = 1 кодрант. В Евангелии бедная вдова пожертвовала в сокровищницу храма две лепты — «всё пропитание своё» (Мк. 12:42).", source: "Нюстрем"),

        DictionaryEntry(id: "локоть", word: "Локоть", definition: "Древняя единица длины — расстояние от локтя до кончика среднего пальца, около 44–52 см. Использовалась при описании скинии, ковчега и Иерусалимского храма.", source: "Нюстрем"),

        DictionaryEntry(id: "стадия", word: "Стадия", definition: "Греческая единица длины около 185 м (600 футов). «Вифания была близ Иерусалима, стадиях в пятнадцати» (Ин. 11:18), то есть около 2,8 км.", source: "Нюстрем"),

        // ─── Архаичные и редкие слова ────────────────────────────────────────

        DictionaryEntry(id: "агнец", word: "Агнец", definition: "Ягнёнок. В В.З. приносился в жертву как прообраз искупительной жертвы. Иисус Христос — «Агнец Божий, Который берёт на Себя грех мира» (Ин. 1:29).", source: "Нюстрем"),

        DictionaryEntry(id: "алавастр", word: "Алавастр", definition: "Небольшой сосуд из алебастра для хранения дорогостоящего мира (благовония). Женщина возлила из алавастра миро на голову Иисуса (Мф. 26:7).", source: "Нюстрем"),

        DictionaryEntry(id: "вретище", word: "Вретище", definition: "Грубая одежда из волосяной ткани или мешковины. Надевалась в знак глубокой скорби, траура и покаяния: «оденутся во вретище» (Иов 16:15; Откр. 11:3).", source: "Нюстрем"),

        DictionaryEntry(id: "горница", word: "Горница", definition: "Верхняя комната (горний этаж) дома. В горнице состоялась Тайная Вечеря и Пятидесятница (Мк. 14:15; Деян. 1:13). Традиционно место собраний первых христиан.", source: "Нюстрем"),

        DictionaryEntry(id: "десница", word: "Десница", definition: "Правая рука. Место чести и власти: «Сидящий одесную Отца» (Символ веры). «Десница Господня» — образ Божьей силы и помощи (Пс. 117:16).", source: "Нюстрем"),

        DictionaryEntry(id: "ефод", word: "Ефод", definition: "Особое священническое облачение из льна и золота, носившееся поверх хитона. Первосвященнический ефод имел наперсник с двенадцатью драгоценными камнями — по числу колен Израиля.", source: "Нюстрем"),

        DictionaryEntry(id: "жезл", word: "Жезл", definition: "Посох, трость или скипетр. Символ власти и поддержки. Жезл Моисея — орудие чудес. «Жезл для наказания» (притч. 13:24). «Железный жезл» — образ власти Мессии (Пс. 2:9).", source: "Нюстрем"),

        DictionaryEntry(id: "кущи", word: "Кущи", definition: "Шалаши, ветвяные шатры. Праздник Кущей (Суккот) — осенний ветхозаветный праздник в память о странствии в пустыне, когда Израиль жил в шатрах (Лев. 23:34–43).", source: "Нюстрем"),

        DictionaryEntry(id: "прокажённый", word: "Прокажённый", definition: "Человек, страдающий проказой — тяжёлой кожной болезнью. Считался ритуально нечистым и изгонялся из общества. Иисус исцелял прокажённых (Мф. 8:2–3; Лк. 17:12–19).", source: "Нюстрем"),

        DictionaryEntry(id: "хитон", word: "Хитон", definition: "Нижняя нательная одежда в виде рубахи без рукавов или с рукавами. «Хитон Иисуса был несшитый, сверху вытканный весь» (Ин. 19:23). Сравни с «одеждой» в Мф. 5:40.", source: "Нюстрем"),

        DictionaryEntry(id: "ясли", word: "Ясли", definition: "Кормушка для скота, вырезанная в скале или сделанная из дерева. «Родила Сына Своего первенца, запеленала Его и положила в ясли» (Лк. 2:7). Место рождения Христа.", source: "Нюстрем"),

        DictionaryEntry(id: "манна", word: "Манна", definition: "Чудесная пища, которой Бог питал израильтян в пустыне сорок лет. Падала с неба по ночам. Иисус называет Себя «Хлебом живым, сшедшим с небес» в противопоставление манне (Ин. 6:31–35).", source: "Нюстрем"),

        DictionaryEntry(id: "манассия", word: "Манассия", definition: "Сын Иосифа. Его колено заняло часть Заиорданья и земли к западу от Иордана. Также имя нечестивого царя Иудейского (696–641 до Р.Х.), покаявшегося в конце жизни (2 Пар. 33).", source: "Нюстрем"),

        DictionaryEntry(id: "осанна", word: "Осанна", definition: "«Спаси нас!» или «Спасение даруй!» (евр. hoshi'a na). Восклицание при входе Господнем в Иерусалим (Мф. 21:9). Из Пс. 117:25–26. В богослужении — возглас хвалы и прославления.", source: "Нюстрем"),

        DictionaryEntry(id: "аминь", word: "Аминь", definition: "«Истинно», «верно», «да будет так» (евр.). В Ветхом Завете — одобрительный ответ народа. В речи Иисуса: «Аминь, аминь говорю вам» — торжественное утверждение. В молитве — завершение.", source: "Нюстрем"),

        DictionaryEntry(id: "аллилуия", word: "Аллилуия", definition: "«Хвалите Господа!» (евр.). Возглас хвалы Богу в псалмах (Пс. 111–117; 145–150). В Откровении — торжественное пение небесных сил (Откр. 19:1–6). Используется в христианском богослужении.", source: "Нюстрем"),

        DictionaryEntry(id: "суккот", word: "Суккот", definition: "Праздник Кущей — один из трёх великих ветхозаветных праздников. Отмечается осенью в память странствия по пустыне. Длился 8 дней; в последний день Иисус произнёс слова о «воде живой» (Ин. 7:37–38).", source: "Нюстрем"),

        DictionaryEntry(id: "суд", word: "Суд", definition: "Правосудие Бога. Страшный Суд — последний суд над всеми людьми по делам их (Мф. 25:31–46; Откр. 20:12). Судии Израиля — вожди-освободители до эпохи царей (Книга Судей).", source: "Нюстрем"),
    ]
}
