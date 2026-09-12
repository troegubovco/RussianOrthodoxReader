//
//  WatchRootView.swift
//  RussianOrthodoxReaderWatch
//
//  Корневой экран: список молитвослова. NavigationStack + плоский List (без
//  .carousel) — «Продолжить», утренние/вечерние по времени суток, моё
//  правило, закладки, поминовение, разделы, настройки.
//

import SwiftUI
import Combine

/// Держит путь навигации, чтобы экран чтения мог вернуться к корню одним
/// движением («Готово» на последнем фрагменте), независимо от глубины стека.
final class WatchNavigationController: ObservableObject {
    @Published var path = NavigationPath()

    func popToRoot() {
        path = NavigationPath()
    }
}

struct WatchRootView: View {
    @StateObject private var nav = WatchNavigationController()
    @ObservedObject private var userData = WatchUserDataStore.shared

    @State private var savedPosition: ReadingPositionStore.Saved?

    private var isAvailable: Bool { PrayersRepository.shared.isAvailable }

    var body: some View {
        NavigationStack(path: $nav.path) {
            List {
                if !isAvailable {
                    Label("База молитв не найдена", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                } else {
                    if let saved = savedPosition {
                        continueRow(saved)
                    }

                    // Планы чтения («Мои чтения») — сразу под «Продолжить»,
                    // выше личных разделов: §5.2 п.4 akathist_psalter_design.md.
                    ForEach(userData.plans) { plan in
                        WatchPlanRow(plan: plan)
                    }

                    // Личное — первым: на часах чаще всего читают именно то,
                    // что отобрали на iPhone («Моё правило», закладки).
                    if !userData.myRuleSlugs.isEmpty {
                        myRuleRow
                    }

                    if !userData.bookmarkSlugs.isEmpty {
                        bookmarksRow
                    }

                    if !userData.hasSnapshot {
                        personalHintRow
                    }

                    ForEach(dailyRows) { info in
                        dailyRow(info)
                    }

                    pominovenieRow

                    NavigationLink(value: WatchRoute.catalog) {
                        Label("Разделы", systemImage: "square.grid.2x2")
                    }
                    .accessibilityElement(children: .combine)

                    NavigationLink(value: WatchRoute.settings) {
                        Label("Настройки", systemImage: "gearshape")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("Молитвы")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .catalog:
                    CatalogView()
                case .prayerList(let category):
                    WatchPrayerListView(category: category)
                case .prayers(let title, let slugs):
                    WatchPrayerListView(title: title, slugs: slugs)
                case .read(let ref):
                    ReaderScreen(ref: ref)
                case .search:
                    SearchView()
                case .settings:
                    WatchSettingsView()
                case .plan(let planUUID):
                    WatchPlanScreen(planUUID: planUUID)
                }
            }
            .task {
                refreshSavedPosition()
                applyDebugLaunchRoute()
            }
            .onAppear { refreshSavedPosition() }
        }
        .environmentObject(nav)
    }

    // MARK: - Отладочный запуск (только DEBUG)

    /// Открывает экран чтения сразу при запуске — для снимков экрана в
    /// симуляторе через `xcrun simctl launch` с переменными окружения:
    ///   SINODAL_WATCH_OPEN=<slug последования, например morning | bookmarks | root | search>
    ///     или plan:<uuid плана> — сразу открыть экран плана чтения (нужен
    ///     SINODAL_WATCH_DEMO_SNAPSHOT=1, чтобы план существовал; demo-plan-akathist
    ///     — uuid демонстрационного плана из демонстрационного снимка ниже).
    ///   SINODAL_WATCH_DEMO_SNAPSHOT=1 — подставить демонстрационное правило,
    ///     закладки и план чтения («Акафист Иисусу Сладчайшему», 12 из 40)
    ///   SINODAL_WATCH_TEXT_STEP=<0…3>   SINODAL_WATCH_FRAGMENT=<индекс>
    ///   SINODAL_WATCH_QUERY=<текст> — с SINODAL_WATCH_OPEN=search, сразу
    ///   выполняет поиск (search_design.md §5 шаг 7) вместо пустого экрана.
    private func applyDebugLaunchRoute() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let slug = env["SINODAL_WATCH_OPEN"], !slug.isEmpty else { return }
        if let step = env["SINODAL_WATCH_TEXT_STEP"].flatMap(Int.init) {
            UserDefaults.standard.set(step, forKey: "watch.textStep")
        }
        if env["SINODAL_WATCH_DEMO_SNAPSHOT"] == "1" {
            // Демонстрационный снимок с iPhone (правило, закладки, план чтения)
            // для снимков экрана.
            let demoPlan = WatchSnapshot.Plan(
                uuid: "demo-plan-akathist",
                kind: "dailyPrayer",
                subjectSlug: "akafisty.akafist-iisusu-sladchajshemu",
                title: "Акафист Иисусу Сладчайшему",
                totalUnits: 40,
                completedCount: 12,
                doneToday: false,
                nextUnitIndex: 12,
                nextUnitLabel: "День 13 из 40",
                nextTargetSlug: "akafisty.akafist-iisusu-sladchajshemu")
            let demo = WatchSnapshot(
                sentAt: Date(),
                myRuleSlugs: ["main.otche-nash", "main.iisusova-molitva", "morning.trisvyatoe", "main.simvol-very"],
                bookmarkSlugs: ["morning.molitva-svyatomu-duhu", "morning.psalom-50", "main.carju-nebesnyj"],
                pomyannik: [], prayerLanguage: nil, showStress: nil,
                plans: [demoPlan])
            if let data = try? demo.encoded() {
                UserDefaults.standard.set(data, forKey: WatchSnapshot.userDefaultsKey)
                NotificationCenter.default.post(name: WatchSnapshot.didChangeNotification, object: nil)
            }
        }
        if slug == "root" { return }
        if slug == "catalog" { nav.path.append(WatchRoute.catalog); return }
        if slug == "search" { nav.path.append(WatchRoute.search); return }
        if slug.hasPrefix("plan:") {
            nav.path.append(WatchRoute.plan(String(slug.dropFirst("plan:".count))))
            return
        }
        if slug == "bookmarks" {
            nav.path.append(WatchRoute.prayers(title: "Закладки",
                                               slugs: WatchSnapshot.loadStored()?.bookmarkSlugs ?? []))
            return
        }
        let fragment = env["SINODAL_WATCH_FRAGMENT"].flatMap(Int.init)
        let title = PrayerCatalog.category(slug: slug)?.title ?? slug
        let ref = ReadingUnitRef(kind: .sequence(categorySlug: slug, title: title),
                                 startFragment: fragment)
        nav.path.append(WatchRoute.read(ref))
        #endif
    }

    // MARK: - «Продолжить»

    private func continueRow(_ saved: ReadingPositionStore.Saved) -> some View {
        NavigationLink(value: WatchRoute.read(resumeRef(saved))) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.circle.fill")
                    .foregroundStyle(WatchTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(saved.unitTitle)
                    Text("\(saved.fragmentLabel) · \(saved.fragmentIndex + 1) из \(saved.fragmentCount)")
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Продолжить чтение: \(saved.unitTitle), \(saved.fragmentIndex + 1) из \(saved.fragmentCount)")
    }

    private func resumeRef(_ saved: ReadingPositionStore.Saved) -> ReadingUnitRef {
        var kind = saved.ref.kind
        if case .rule = kind, !userData.myRuleSlugs.isEmpty {
            kind = .rule(slugs: userData.myRuleSlugs)
        }
        return ReadingUnitRef(kind: kind, startFragment: saved.fragmentIndex)
    }

    /// Проверяет, что сохранённая позиция свежая (<7 дней) и что её ещё можно
    /// построить (молитвы/правило не пропали); иначе — тихо забывает её.
    private func refreshSavedPosition() {
        guard isAvailable, let saved = ReadingPositionStore.load() else {
            savedPosition = nil
            return
        }
        guard ReadingPositionStore.isFresh(saved) else {
            savedPosition = nil
            return
        }

        var kind = saved.ref.kind
        if case .rule = kind, !userData.myRuleSlugs.isEmpty {
            kind = .rule(slugs: userData.myRuleSlugs)
        }
        let prayers = ReadingUnit.loadPrayers(for: ReadingUnitRef(kind: kind))
        guard !prayers.isEmpty else {
            ReadingPositionStore.clear()
            savedPosition = nil
            return
        }
        savedPosition = saved
    }

    // MARK: - Утренние/вечерние — порядок по времени суток

    private struct DailyInfo: Identifiable {
        let id: String
        let title: String
    }

    private var dailyRows: [DailyInfo] {
        let morning = DailyInfo(id: "morning", title: PrayerCatalog.category(slug: "morning")?.title ?? "Утренние молитвы")
        let evening = DailyInfo(id: "evening", title: PrayerCatalog.category(slug: "evening")?.title ?? "Вечерние молитвы")
        let hour = Calendar.current.component(.hour, from: Date())
        let morningFirst = (3..<16).contains(hour)
        return morningFirst ? [morning, evening] : [evening, morning]
    }

    private func dailyRow(_ info: DailyInfo) -> some View {
        NavigationLink(value: WatchRoute.read(ReadingUnitRef(kind: .sequence(categorySlug: info.id, title: info.title)))) {
            Label(info.title, systemImage: info.id == "morning" ? "sun.max.fill" : "moon.stars.fill")
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Моё правило / Закладки / Поминовение

    /// Фон выделенных строк — золотой оттенок на чёрном.
    private var personalRowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WatchTheme.accent.opacity(0.16))
    }

    private func personalRow(title: String, count: Int, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(WatchTheme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(count.molitvCount)
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.muted)
            }
        }
        .padding(.vertical, 4)
    }

    private var myRuleRow: some View {
        NavigationLink(value: WatchRoute.read(ReadingUnitRef(kind: .rule(slugs: userData.myRuleSlugs)))) {
            personalRow(title: "Моё правило", count: userData.myRuleSlugs.count, systemImage: "list.star")
        }
        .listRowBackground(personalRowBackground)
        .accessibilityElement(children: .combine)
    }

    private var bookmarksRow: some View {
        NavigationLink(value: WatchRoute.prayers(title: "Закладки", slugs: userData.bookmarkSlugs)) {
            personalRow(title: "Закладки", count: userData.bookmarkSlugs.count, systemImage: "bookmark.fill")
        }
        .listRowBackground(personalRowBackground)
        .accessibilityElement(children: .combine)
    }

    /// Пока снимок с iPhone не приходил — подсказка, откуда берётся личное.
    private var personalHintRow: some View {
        Text("Моё правило и закладки появятся, когда откроете «Синодал» на iPhone")
            .font(.footnote)
            .foregroundStyle(WatchTheme.muted)
            .listRowBackground(Color.clear)
    }

    private var pominovenieCategory: PrayerCategory {
        PrayerCatalog.category(slug: "pominovenie")
            ?? PrayerCategory(id: -1, slug: "pominovenie", title: "Поминовение", subtitle: nil,
                               icon: nil, sortOrder: 0, isSequence: false)
    }

    private var pominovenieRow: some View {
        NavigationLink(value: WatchRoute.prayerList(pominovenieCategory)) {
            Label("Поминовение", systemImage: "person.2.fill")
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    WatchRootView()
}
