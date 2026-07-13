#if os(macOS)
import SwiftUI

/// Выбор в оглавлении молитвослова (macOS).
enum PrayersMacSelection: Hashable {
    case pomyannik
    case myRuleRead
    case sequence(String)   // slug категории-последования
    case prayer(String)     // slug молитвы
}

/// macOS-раскладка раздела «Молитвы»: слева постоянное оглавление
/// (категории → молитвы), справа текст. Использует широкое окно вместо
/// пустых полей и позволяет прыгать между молитвами без «назад».
struct PrayersMacView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var userData = PrayersUserDataStore.shared
    private let theme = OrthodoxColors.fallback

    @State private var selection: PrayersMacSelection?
    @State private var nodes: [CatNode] = []
    /// Оглавление можно скрыть — состояние переживает перезапуск.
    @AppStorage("prayersMacOutlineVisible") private var outlineVisible = true

    struct CatNode: Identifiable {
        let category: PrayerCategory
        let children: [CatNode]
        let prayers: [PrayerSummary]
        var id: Int { category.id }
    }

    var body: some View {
        HSplitView {
            if outlineVisible {
                sidebar
                    .frame(minWidth: 250, idealWidth: 310, maxWidth: 420)
            }

            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        outlineVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.squares.leading")
                }
                .help(outlineVisible ? "Скрыть оглавление" : "Показать оглавление")
            }
        }
        .prayerSearchToolbar()
        .task {
            guard nodes.isEmpty else { return }
            let repo = PrayersRepository.shared
            func node(for category: PrayerCategory) -> CatNode {
                CatNode(category: category,
                        children: repo.subcategories(of: category.id).map(node(for:)),
                        prayers: repo.prayers(inCategory: category.slug))
            }
            nodes = repo.categories().map(node(for:))
            if selection == nil {
                selection = .sequence("morning")
            }
        }
    }

    // MARK: - Оглавление

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Помянник", systemImage: "book.pages")
                    .tag(PrayersMacSelection.pomyannik)

                if !userData.myRuleSlugs.isEmpty {
                    Label("Моё правило", systemImage: "list.star")
                        .tag(PrayersMacSelection.myRuleRead)
                }
            }

            ForEach(nodes) { node in
                Section(node.category.title) {
                    categoryRows(node)

                    ForEach(node.children) { child in
                        DisclosureGroup {
                            categoryRows(child)
                        } label: {
                            Label(child.category.title,
                                  systemImage: child.category.icon ?? "book.closed")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Строки одной категории: «Читать подряд» (для последований) + молитвы.
    /// Иерархия в базе двухуровневая, поэтому рекурсия не нужна.
    @ViewBuilder
    private func categoryRows(_ node: CatNode) -> some View {
        if node.category.isSequence {
            Label("Читать подряд", systemImage: "text.justify.leading")
                .tag(PrayersMacSelection.sequence(node.category.slug))
        }

        ForEach(node.prayers) { prayer in
            prayerRow(prayer)
        }
    }

    private func prayerRow(_ prayer: PrayerSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(prayer.title)
                .lineLimit(2)
            if let subtitle = prayer.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .tag(PrayersMacSelection.prayer(prayer.slug))
    }

    // MARK: - Текст

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case nil:
            VStack(spacing: 10) {
                OrthodoxCrossIcon(color: theme.muted)
                    .frame(width: 26, height: 36)
                Text("Выберите молитву в оглавлении")
                    .foregroundColor(theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .pomyannik:
            PomyannikView()

        case .myRuleRead:
            PrayerSequenceView(title: "Моё правило", slugs: userData.myRuleSlugs)
                .id(userData.myRuleSlugs)

        case .sequence(let slug):
            if let category = findCategory(slug) {
                PrayerSequenceView(category: category)
                    .id(slug)
            }

        case .prayer(let slug):
            // .id — сбрасывает @State-кэш PrayerDetailView при смене выбора.
            PrayerDetailView(slug: slug)
                .id(slug)
        }
    }

    private func findCategory(_ slug: String) -> PrayerCategory? {
        func search(_ list: [CatNode]) -> PrayerCategory? {
            for node in list {
                if node.category.slug == slug { return node.category }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(nodes)
    }
}
#endif
