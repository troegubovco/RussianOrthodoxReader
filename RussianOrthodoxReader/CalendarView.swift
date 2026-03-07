import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var appState: AppState
    @State private var viewYear: Int
    @State private var viewMonth: Int
    @State private var selectedDay: Int? = nil
    @StateObject private var viewModel = CalendarViewModel()

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private let daysOfWeek = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    init() {
        let cal = Calendar.current
        let now = Date()
        _viewYear = State(initialValue: cal.component(.year, from: now))
        _viewMonth = State(initialValue: cal.component(.month, from: now) - 1)
    }

    private var readings: [Int: LiturgicalDay] {
        viewModel.days
    }

    private var firstWeekdayOffset: Int {
        let date = Calendar.current.date(from: DateComponents(year: viewYear, month: viewMonth + 1, day: 1))!
        let dow = Calendar.current.component(.weekday, from: date)
        return (dow + 5) % 7
    }

    private var daysInMonth: Int {
        Calendar.current.range(
            of: .day,
            in: .month,
            for: Calendar.current.date(from: DateComponents(year: viewYear, month: viewMonth + 1, day: 1))!
        )?.count ?? 30
    }

    private var isCurrentMonth: Bool {
        let cal = Calendar.current
        let now = Date()
        return viewYear == cal.component(.year, from: now) && viewMonth == cal.component(.month, from: now) - 1
    }

    private func isToday(_ day: Int) -> Bool {
        guard isCurrentMonth else { return false }
        return day == Calendar.current.component(.day, from: Date())
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Календарь")
                        .font(AppFont.medium(typ.title))
                        .foregroundColor(theme.text)
                        .padding(.top, isLandscape ? 12 : 8)

                    HStack {
                        Button(action: prevMonth) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(theme.accent)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Предыдущий месяц")

                        Spacer()

                        Text("\(LiturgicalCalendar.monthNames[viewMonth]) \(String(viewYear))")
                            .font(AppFont.medium(typ.callout))
                            .foregroundColor(theme.text)

                        Spacer()

                        Button(action: nextMonth) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(theme.accent)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Следующий месяц")
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 2) {
                        ForEach(daysOfWeek, id: \.self) { day in
                            Text(day)
                                .font(AppFont.semiBold(typ.micro))
                                .foregroundColor(day == "Вс" ? theme.accent : theme.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 2) {
                        ForEach(Array(-firstWeekdayOffset ..< 0), id: \.self) { _ in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                        }

                        ForEach(1...daysInMonth, id: \.self) { day in
                            CalendarDayCell(
                                day: day,
                                reading: readings[day],
                                isToday: isToday(day),
                                isSelected: selectedDay == day
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedDay = selectedDay == day ? nil : day
                                }
                            }
                        }
                    }

                    if viewModel.isLoading {
                        ProgressView()
                            .padding(.top, 8)
                    }

                    if let day = selectedDay, let info = readings[day] {
                        DayDetailCard(day: day, month: viewMonth, info: info)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
        .task(id: "\(viewYear)-\(viewMonth)") {
            await viewModel.loadMonth(year: viewYear, month: viewMonth)
        }
        .onChange(of: appState.calendarResetTrigger) { _, _ in
            goToCurrentMonth()
        }
    }

    private func goToCurrentMonth() {
        let cal = Calendar.current
        let now = Date()
        let currentYear = cal.component(.year, from: now)
        let currentMonth = cal.component(.month, from: now) - 1
        guard viewYear != currentYear || viewMonth != currentMonth else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDay = nil
            viewYear = currentYear
            viewMonth = currentMonth
        }
    }

    private func prevMonth() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDay = nil
            if viewMonth == 0 {
                viewMonth = 11
                viewYear -= 1
            } else {
                viewMonth -= 1
            }
        }
    }

    private func nextMonth() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDay = nil
            if viewMonth == 11 {
                viewMonth = 0
                viewYear += 1
            } else {
                viewMonth += 1
            }
        }
    }
}

struct CalendarDayCell: View {
    let day: Int
    let reading: LiturgicalDay?
    let isToday: Bool
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.accent : isToday ? theme.todayHighlight : theme.card)

                VStack(spacing: 2) {
                    Text("\(day)")
                        .font(AppFont.regular(typ.subheadline))
                        .fontWeight(isToday || isSelected ? .bold : .regular)
                        .foregroundColor(
                            isSelected ? .white :
                            isToday ? theme.accent :
                            reading?.isSunday == true ? theme.accent :
                            theme.text
                        )

                    if let reading, reading.isFastDay && !isSelected {
                        Circle()
                            .fill(theme.fastText)
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day), \(reading?.saintOfDay ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct DayDetailCard: View {
    let day: Int
    let month: Int
    let info: LiturgicalDay

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(day) \(LiturgicalCalendar.monthNames[month])")
                    .sectionHeader()

                Spacer()

                if info.isFastDay {
                    Text(info.fastingLevel.rawValue)
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(theme.fastText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.fastBackground))
                }
            }

            Text(info.saintOfDay)
                .font(AppFont.regular(typ.callout))
                .foregroundColor(theme.text)
                .lineSpacing(4)

            Divider().background(theme.border)

            VStack(alignment: .leading, spacing: 12) {
                let hasApostol = info.apostolReading != "—"
                let hasGospel  = info.gospelReading  != "—"
                let extraGroups = ExtraReadingGroup.grouped(from: info.extraReferences)

                if !hasApostol && !hasGospel && extraGroups.isEmpty {
                    Text("Апостол и Евангелие в этот день не читаются")
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)
                } else {
                    if hasApostol {
                        readingRow(label: "Апостол", value: info.apostolReading)
                    }
                    if hasGospel {
                        readingRow(label: "Евангелие", value: info.gospelReading)
                    }
                    ForEach(extraGroups) { group in
                        readingRow(
                            label: ExtraReadingGroup.russianSourceLabel(group.sourceLabel),
                            value: group.displayRef
                        )
                    }
                }

                if let tone = info.tone {
                    HStack(spacing: 8) {
                        Text("Глас:")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                        Text("\(tone)")
                            .font(AppFont.semiBold(typ.subheadline))
                            .foregroundColor(theme.accent)
                    }
                }

                if let message = info.dataAvailabilityMessage {
                    Text(message)
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(theme.muted)
                }
            }
        }
        .padding(24)
        .cardStyle()
    }

    @ViewBuilder
    private func readingRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text("\(label):")
                .font(AppFont.regular(typ.caption))
                .foregroundColor(theme.muted)
            Text(value)
                .font(AppFont.medium(typ.subheadline))
                .foregroundColor(theme.text)
        }
    }

}

#Preview {
    CalendarView()
        .environmentObject(AppState())
}
