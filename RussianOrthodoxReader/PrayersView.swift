import SwiftUI

// MARK: - Маршруты раздела «Молитвы»

enum PrayersRoute: Hashable {
    case category(PrayerCategory)
    case prayer(slug: String)
    case sequence(PrayerCategory)
    case pomyannik
    case myRule
    case myRuleRead([String])
}

/// Кастомный таб-бар ContentView добавляется через safeAreaInset снаружи
/// NavigationStack, а NavigationStack не пробрасывает этот inset своим
/// экранам — ScrollView внутри уходит под таб-бар. Каждый экран раздела
/// добавляет себе нижний отступ высотой таб-бара сам.
extension View {
    @ViewBuilder
    func tabBarBottomClearance() -> some View {
        #if os(iOS)
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 62)
        }
        #else
        self
        #endif
    }
}

/// Восьмиконечный православный крест в линейном стиле — вместо эмодзи ☦,
/// которое системный шрифт рисует цветным.
struct OrthodoxCrossIcon: View {
    var color: Color
    var lineWidth: CGFloat = 1.6

    var body: some View {
        OrthodoxCrossShape()
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

private struct OrthodoxCrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        // Вертикаль
        p.move(to: CGPoint(x: cx, y: rect.minY))
        p.addLine(to: CGPoint(x: cx, y: rect.maxY))
        // Верхняя малая перекладина
        p.move(to: CGPoint(x: cx - 0.20 * w, y: rect.minY + 0.18 * h))
        p.addLine(to: CGPoint(x: cx + 0.20 * w, y: rect.minY + 0.18 * h))
        // Средняя большая перекладина
        p.move(to: CGPoint(x: cx - 0.38 * w, y: rect.minY + 0.40 * h))
        p.addLine(to: CGPoint(x: cx + 0.38 * w, y: rect.minY + 0.40 * h))
        // Нижняя косая перекладина (левый конец выше)
        p.move(to: CGPoint(x: cx - 0.26 * w, y: rect.minY + 0.66 * h))
        p.addLine(to: CGPoint(x: cx + 0.26 * w, y: rect.minY + 0.80 * h))
        return p
    }
}

/// Просфора в линейном стиле — двухъярусный круглый хлебец (широкий низ,
/// меньший верхний ярус) с печатью наверху: крест внутри квадрата, чьи
/// перекладины делят печать на четыре части (места букв «ИС ХС / НИ КА»).
/// Заменяет `cup.and.saucer`, читающийся как кофейная чашка, в карточке
/// категории «Подготовка к Причащению».
struct ProsphoraIcon: View {
    var color: Color
    var lineWidth: CGFloat = 1.6

    var body: some View {
        ProsphoraShape()
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

private struct ProsphoraShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let minY = rect.minY

        // Два коротких «барабана» (низкий широкий + низкий узкий), почти без
        // конусности по бокам — так читается как приплюснутый круглый
        // хлебец, а не конус/лампа/юла. Нижний ярус:
        let bottomBaseY = minY + 0.88 * h
        let bottomRimY = minY + 0.64 * h
        let bottomRX = 0.46 * w
        let bottomRimRX = 0.44 * w // почти тот же радиус — борта нижнего яруса вертикальны
        let bottomRY = 0.05 * h

        p.addEllipse(in: CGRect(x: cx - bottomRX, y: bottomBaseY - bottomRY,
                                 width: bottomRX * 2, height: bottomRY * 2))
        p.addEllipse(in: CGRect(x: cx - bottomRimRX, y: bottomRimY - bottomRY * 0.9,
                                 width: bottomRimRX * 2, height: bottomRY * 1.8))
        p.move(to: CGPoint(x: cx - bottomRX, y: bottomBaseY))
        p.addLine(to: CGPoint(x: cx - bottomRimRX, y: bottomRimY))
        p.move(to: CGPoint(x: cx + bottomRX, y: bottomBaseY))
        p.addLine(to: CGPoint(x: cx + bottomRimRX, y: bottomRimY))

        // Уступ — плоская «полочка» нижнего яруса, на которую поставлен
        // верхний, меньший ярус.
        let topBaseRX = 0.24 * w
        p.move(to: CGPoint(x: cx - bottomRimRX, y: bottomRimY))
        p.addLine(to: CGPoint(x: cx - topBaseRX, y: bottomRimY))
        p.move(to: CGPoint(x: cx + bottomRimRX, y: bottomRimY))
        p.addLine(to: CGPoint(x: cx + topBaseRX, y: bottomRimY))

        // Верхний ярус — такой же короткий барабан, поменьше.
        let topRimY = minY + 0.34 * h
        let topRimRX = 0.22 * w
        let topRY = 0.045 * h

        p.addEllipse(in: CGRect(x: cx - topBaseRX, y: bottomRimY - topRY,
                                 width: topBaseRX * 2, height: topRY * 2))
        p.addEllipse(in: CGRect(x: cx - topRimRX, y: topRimY - topRY,
                                 width: topRimRX * 2, height: topRY * 2))
        p.move(to: CGPoint(x: cx - topBaseRX, y: bottomRimY))
        p.addLine(to: CGPoint(x: cx - topRimRX, y: topRimY))
        p.move(to: CGPoint(x: cx + topBaseRX, y: bottomRimY))
        p.addLine(to: CGPoint(x: cx + topRimRX, y: topRimY))

        // Печать: квадрат с крестом внутри (крест делит квадрат на 4 части —
        // места букв «ИС ХС / НИ КА»), стоит на верхней плоскости хлеба.
        let sealHalf = 0.14 * w
        let sealTop = minY + 0.06 * h
        let sealBottom = minY + 0.26 * h
        p.addRect(CGRect(x: cx - sealHalf, y: sealTop, width: sealHalf * 2, height: sealBottom - sealTop))
        p.move(to: CGPoint(x: cx, y: sealTop))
        p.addLine(to: CGPoint(x: cx, y: sealBottom))
        p.move(to: CGPoint(x: cx - sealHalf, y: (sealTop + sealBottom) / 2))
        p.addLine(to: CGPoint(x: cx + sealHalf, y: (sealTop + sealBottom) / 2))

        return p
    }
}

// MARK: - Корневой экран «Молитвы»

struct PrayersView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    @ObservedObject private var userData = PrayersUserDataStore.shared
    private let theme = OrthodoxColors.fallback

    @State private var path: [PrayersRoute] = []
    @State private var categories: [PrayerCategory] = []
    @State private var showSearch = false

    private var bookmarkedPrayers: [PrayerSummary] {
        PrayersRepository.shared.prayers(slugs: userData.bookmarkSlugs).map {
            PrayerSummary(id: $0.id, slug: $0.slug, title: $0.title,
                          subtitle: $0.subtitle, takesNames: $0.takesNames)
        }
    }

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        #if os(macOS)
        // На широком окне Mac — двухколоночная раскладка: оглавление + текст.
        PrayersMacView()
        #else
        stackBody
        #endif
    }

    private var stackBody: some View {
        NavigationStack(path: $path) {
            GeometryReader { proxy in
                let isLandscape = proxy.size.width > proxy.size.height

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Молитвы")
                                .font(AppFont.medium(typ.title))
                                .foregroundColor(theme.text)

                            Spacer()

                            Button {
                                showSearch = true
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(theme.accent)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Поиск молитв")
                        }
                        .padding(.top, isLandscape ? 12 : 8)

                        if categories.isEmpty {
                            Text("Молитвослов недоступен")
                                .font(AppFont.regular(typ.body))
                                .foregroundColor(theme.muted)
                                .padding(.top, 24)
                        } else {
                            Button {
                                path.append(.pomyannik)
                            } label: {
                                PomyannikCard()
                            }
                            .buttonStyle(.plain)

                            // «Мои чтения» — сразу под помянником, выше «Моего
                            // правила» (§5.2 п.2 akathist_psalter_design.md).
                            // Без фильтра — все активные планы; отфильтрованный
                            // вариант для вкладки «Библия» подключает пакет D.
                            // onOpen — переход к текущей единице плана (акафист,
                            // часть канона или молитва по кафизме); для кафизмы
                            // по «Славам» цель тоже находится в молитвослове,
                            // поэтому `prayerSlug` подходит для всех видов плана.
                            MyReadingsCard(onOpen: { plan in
                                let target = plan.kind.target(for: plan.nextUnitIndex)
                                path.append(.prayer(slug: target.prayerSlug))
                            })

                            if !userData.myRuleSlugs.isEmpty {
                                Button {
                                    path.append(.myRule)
                                } label: {
                                    MyRuleCard(count: userData.myRuleSlugs.count)
                                }
                                .buttonStyle(.plain)
                            }

                            let bookmarks = bookmarkedPrayers
                            if !bookmarks.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Закладки")
                                        .sectionHeader()

                                    PrayerRowsCard(prayers: bookmarks) { slug in
                                        path.append(.prayer(slug: slug))
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                if !bookmarks.isEmpty {
                                    Text("Разделы")
                                        .sectionHeader()
                                }

                                VStack(spacing: 12) {
                                    ForEach(categories) { category in
                                        Button {
                                            path.append(.category(category))
                                        } label: {
                                            PrayerCategoryCard(category: category)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .readableContentWidth()
                    .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                    .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
                }
                .tabBarBottomClearance()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(theme.background.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: PrayersRoute.self) { route in
                switch route {
                case .category(let category):
                    PrayerListView(category: category, path: $path)
                case .prayer(let slug):
                    PrayerDetailView(slug: slug)
                case .sequence(let category):
                    PrayerSequenceView(category: category)
                case .pomyannik:
                    PomyannikView()
                case .myRule:
                    MyRuleView(path: $path)
                case .myRuleRead(let slugs):
                    PrayerSequenceView(title: "Моё правило", slugs: slugs)
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            PrayerSearchView()
                .environmentObject(appState)
        }
        .task {
            if categories.isEmpty {
                categories = PrayersRepository.shared.categories()
            }
            #if DEBUG
            // SINODAL_OPEN_PRAYER=<slug> / SINODAL_OPEN_PLAN_SETUP=<slug> /
            // SINODAL_OPEN_CONTENTS=<slug> / SINODAL_OPEN_TYPOGRAPHY=<slug> —
            // все открывают молитву; соответствующий лист открывает уже сам
            // PrayerDetailView, увидев совпадение слага в своём .task.
            if let slug = DebugLaunchHooks.openPrayerSlug
                ?? DebugLaunchHooks.openPlanSetupSlug
                ?? DebugLaunchHooks.openContentsSlug
                ?? DebugLaunchHooks.openTypographySlug,
               path.isEmpty {
                path = [.prayer(slug: slug)]
            }
            if DebugLaunchHooks.openAkafistyList, path.isEmpty,
               let category = PrayersRepository.shared.category(slug: "akafisty") {
                path = [.category(category)]
            }
            #endif
        }
        .onChange(of: appState.prayersResetTrigger) { _, _ in
            path.removeAll()
        }
    }
}

// MARK: - Поиск молитв

/// Кнопка поиска в тулбаре — доступна на каждом экране молитвослова.
private struct PrayerSearchToolbar: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var showSearch = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(OrthodoxColors.fallback.accent)
                    }
                    .accessibilityLabel("Поиск молитв")
                }
            }
            .sheet(isPresented: $showSearch) {
                PrayerSearchView()
                    .environmentObject(appState)
            }
    }
}

extension View {
    func prayerSearchToolbar() -> some View {
        modifier(PrayerSearchToolbar())
    }
}

struct PrayerSearchView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    @State private var query = ""
    @State private var results: [PrayerSearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    /// Отдельный от родительского PrayersView стек — этот экран открывается
    /// шитом со своим NavigationStack. Переиспользует PrayersRoute, поэтому
    /// разделы-результаты (search_design.md §3.4, Tier 2) открываются тем же
    /// PrayerListView/PrayerSequenceView, что и обычный просмотр каталога.
    @State private var path: [PrayersRoute] = []
    @FocusState private var searchFocused: Bool

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    /// Поле поиска в стиле приложения — системный .searchable в шите
    /// на macOS выглядит чужеродно и обрезанно.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.muted)

            TextField("Название или текст молитвы", text: $query)
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .autocorrectionDisabled()

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                searchField

                Group {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    placeholder
                } else if results.isEmpty {
                    Text("Ничего не найдено")
                        .font(AppFont.regular(typ.body))
                        .foregroundColor(theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                if let route = route(for: result) {
                                    NavigationLink(value: route) {
                                        resultRow(result)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if index < results.count - 1 {
                                    Rectangle()
                                        .fill(theme.border)
                                        .frame(height: 0.5)
                                        .padding(.leading, 20)
                                }
                            }
                        }
                        .background(theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .readableContentWidth()
                        .padding(16)
                    }
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Поиск")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            #endif
            .navigationDestination(for: PrayersRoute.self) { route in
                switch route {
                case .category(let category):
                    PrayerListView(category: category, path: $path)
                case .prayer(let slug):
                    PrayerDetailView(slug: slug)
                case .sequence(let category):
                    PrayerSequenceView(category: category)
                case .pomyannik, .myRule, .myRuleRead:
                    EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, newValue in
            performSearch(newValue)
        }
    }

    /// Раздел-результат (Tier 2) ведёт в тот же PrayerListView, что и обычный
    /// просмотр каталога; молитва — как раньше, в PrayerDetailView.
    private func route(for result: PrayerSearchResult) -> PrayersRoute? {
        switch result.kind {
        case .prayer:
            return .prayer(slug: result.slug)
        case .category(let slug):
            guard let category = PrayersRepository.shared.category(slug: slug) else { return nil }
            return .category(category)
        }
    }

    /// Дебаунс ~120 мс (search_design.md §3.8) — с FTS5 сам поиск укладывается
    /// в доли миллисекунды, это чисто косметика против перезапуска на каждый
    /// символ длинного запроса.
    private func performSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let found = PrayersRepository.shared.search(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.muted)
            Text("Введите название или слова из молитвы")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    /// Обычная молитва — заголовок, подзаголовок (если есть) и раздел.
    /// Раздел-результат (Tier 2, search_design.md §3.4) — отдельный стиль
    /// строки: иконка папки вместо контекстной строки снизу, без categoryTitle
    /// (для .category она всегда пустая).
    @ViewBuilder
    private func resultRow(_ result: PrayerSearchResult) -> some View {
        switch result.kind {
        case .prayer:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(AppFont.regular(typ.callout))
                        .foregroundColor(theme.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if let subtitle = result.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(AppFont.regular(typ.footnote))
                            .foregroundColor(theme.muted)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                    }
                    Text(result.categoryTitle)
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        case .category:
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(theme.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(AppFont.medium(typ.callout))
                        .foregroundColor(theme.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if let subtitle = result.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(AppFont.regular(typ.footnote))
                            .foregroundColor(theme.muted)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(theme.accent.opacity(0.06))
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Карточка помянника

private struct PomyannikCard: View {
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        HStack(spacing: 16) {
            OrthodoxCrossIcon(color: theme.accent)
                .frame(width: 22, height: 30)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("Помянник")
                    .font(AppFont.medium(typ.callout))
                    .foregroundColor(theme.text)

                Text("О здравии и о упокоении")
                    .font(AppFont.regular(typ.footnote))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.todayHighlight)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Помянник, о здравии и о упокоении")
    }
}

// MARK: - Карточка категории

private struct PrayerCategoryCard: View {
    let category: PrayerCategory

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        HStack(spacing: 16) {
            // Просфора вместо `cup.and.saucer` (кофейная чашка на вид) для
            // категории «Подготовка к Причащению». Источник данных
            // (Tools/data/molitvoslov_sources.json) пока хранит старое имя
            // "cup.and.saucer" — сопоставляем оба, пока его не переключат на
            // "prosphora".
            if category.icon == "prosphora" || category.icon == "cup.and.saucer" {
                ProsphoraIcon(color: theme.accent)
                    .frame(width: 27, height: 22)
                    .frame(width: 40)
            } else {
                Image(systemName: category.icon ?? "book.closed")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(theme.accent)
                    .frame(width: 40)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(category.title)
                    .font(AppFont.medium(typ.callout))
                    .foregroundColor(theme.text)
                    .multilineTextAlignment(.leading)

                if let subtitle = category.subtitle {
                    Text(subtitle)
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(category.title)
    }
}

// MARK: - Список молитв категории

struct PrayerListView: View {
    let category: PrayerCategory
    @Binding var path: [PrayersRoute]

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    @State private var prayers: [PrayerSummary] = []
    @State private var subcategories: [PrayerCategory] = []

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.title)
                            .font(AppFont.medium(typ.title))
                            .foregroundColor(theme.text)

                        if let subtitle = category.subtitle {
                            Text(subtitle)
                                .font(AppFont.regular(typ.footnote))
                                .foregroundColor(theme.muted)
                        }

                        // Подсказка про «Читать ежедневно» там, где её
                        // естественно искать — списки акафистов и Псалтири
                        // (§5.4 akathist_psalter_design.md): без неё функция
                        // остаётся незаметной для тех, кто листает раздел, а
                        // не заходит в конкретный текст.
                        if let hint = Self.planHint(forCategorySlug: category.slug) {
                            Text(hint)
                                .font(AppFont.regular(typ.footnote))
                                .foregroundColor(theme.muted)
                        }
                    }
                    .padding(.top, isLandscape ? 12 : 8)

                    if category.isSequence {
                        Button {
                            path.append(.sequence(category))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "text.justify.leading")
                                    .font(.system(size: 17, weight: .medium))
                                Text("Читать подряд")
                                    .font(AppFont.medium(typ.callout))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .opacity(0.7)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(theme.accent)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Читать \(category.title) подряд")
                    }

                    if !subcategories.isEmpty {
                        VStack(spacing: 12) {
                            ForEach(subcategories) { subcategory in
                                Button {
                                    path.append(.category(subcategory))
                                } label: {
                                    PrayerCategoryCard(category: subcategory)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !prayers.isEmpty {
                        PrayerRowsCard(prayers: prayers) { slug in
                            path.append(.prayer(slug: slug))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableContentWidth()
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
            }
            .tabBarBottomClearance()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        #endif
        .prayerSearchToolbar()
        .task {
            if prayers.isEmpty && subcategories.isEmpty {
                prayers = PrayersRepository.shared.prayers(inCategory: category.slug)
                subcategories = PrayersRepository.shared.subcategories(of: category.id)
            }
        }
    }

    private static func planHint(forCategorySlug slug: String) -> String? {
        switch slug {
        case "akafisty":
            return "Любой акафист можно читать ежедневно — 7, 12 или 40 дней: откройте акафист и нажмите «Читать ежедневно»."
        case "psaltir":
            return "Псалтирь можно читать по плану — по кафизме в день."
        default:
            return nil
        }
    }
}

// MARK: - Карточка со списком молитв (строки с разделителями)

struct PrayerRowsCard: View {
    let prayers: [PrayerSummary]
    let onSelect: (String) -> Void

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(prayers.enumerated()), id: \.element.id) { index, prayer in
                Button {
                    onSelect(prayer.slug)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prayer.title)
                                .font(AppFont.regular(typ.callout))
                                .foregroundColor(theme.text)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)

                            if let subtitle = prayer.subtitle {
                                Text(subtitle)
                                    .font(AppFont.regular(typ.footnote))
                                    .foregroundColor(theme.muted)
                                    .multilineTextAlignment(.leading)
                            }
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.muted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < prayers.count - 1 {
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: 0.5)
                        .padding(.leading, 20)
                }
            }
        }
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    PrayersView()
        .environmentObject(AppState())
}
