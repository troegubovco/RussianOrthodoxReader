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
        NavigationStack {
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
                                NavigationLink(value: result.slug) {
                                    resultRow(result)
                                }
                                .buttonStyle(.plain)

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
            #endif
            .navigationDestination(for: String.self) { slug in
                PrayerDetailView(slug: slug)
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
            results = PrayersRepository.shared.search(query: newValue)
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

    private func resultRow(_ result: PrayerSearchResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(AppFont.regular(typ.body))
                    .foregroundColor(theme.text)
                    .multilineTextAlignment(.leading)
                Text(result.categoryTitle)
                    .font(AppFont.regular(typ.caption))
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
            Image(systemName: category.icon ?? "book.closed")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(theme.accent)
                .frame(width: 40)

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
                                .font(AppFont.regular(typ.body))
                                .foregroundColor(theme.text)
                                .multilineTextAlignment(.leading)

                            if let subtitle = prayer.subtitle {
                                Text(subtitle)
                                    .font(AppFont.regular(typ.caption))
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
