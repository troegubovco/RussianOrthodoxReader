import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var calendarService: AzbykaCalendarService
    @EnvironmentObject var tabState: TabNavigationState
    
    private let theme = OrthodoxTheme.shared
    private let weekDays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
    private let monthNames = [
        "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
        "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"
    ]
    
    private var year: Int { tabState.calendarYear }
    private var month: Int { tabState.calendarMonth }
    
    private var daysInMonth: Int {
        let cal = Calendar.current
        let comps = DateComponents(year: year, month: month)
        guard let date = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: date) else { return 30 }
        return range.count
    }
    
    /// Day of week for the 1st of the month (0=Mon, 6=Sun)
    private var firstWeekday: Int {
        let cal = Calendar.current
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: 1)) else { return 0 }
        let dow = cal.component(.weekday, from: date)  // 1=Sun, 2=Mon...7=Sat
        return (dow + 5) % 7  // Convert to 0=Mon
    }
    
    private func isToday(_ day: Int) -> Bool {
        let now = Date()
        let cal = Calendar.current
        return day == cal.component(.day, from: now)
            && month == cal.component(.month, from: now)
            && year == cal.component(.year, from: now)
    }
    
    var body: some View {
        NavigationStack(path: $tabState.navigationPath) {
            ScrollView {
                VStack(spacing: 16) {
                    // Month navigation
                    monthHeader
                    
                    // Weekday labels
                    weekdayRow
                    
                    // Calendar grid
                    calendarGrid
                    
                    // Selected day details
                    if let selectedDay = tabState.selectedCalendarDay,
                       let dayData = calendarService.getCachedDay(year: year, month: month, day: selectedDay) {
                        dayDetailCard(day: selectedDay, data: dayData)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .padding(.bottom, 120)
            }
            .background(Color(hex: "FAF8F5"))
            .task {
                await calendarService.fetchMonth(year: year, month: month)
            }
            .onChange(of: month) { _, _ in
                Task { await calendarService.fetchMonth(year: year, month: month) }
            }
            .onChange(of: year) { _, _ in
                Task { await calendarService.fetchMonth(year: year, month: month) }
            }
        }
    }
    
    // MARK: - Month Header
    
    private var monthHeader: some View {
        HStack {
            Button {
                prevMonth()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Предыдущий месяц")
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(monthNames[month - 1])
                    .font(.custom("CormorantGaramond-SemiBold", size: 22))
                    .foregroundColor(theme.text)
                Text(String(year))
                    .font(.custom("CormorantGaramond-Regular", size: 14))
                    .foregroundColor(theme.muted)
            }
            
            Spacer()
            
            Button {
                nextMonth()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Следующий месяц")
        }
    }
    
    // MARK: - Weekday Row
    
    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekDays, id: \.self) { day in
                Text(day)
                    .font(.custom("CormorantGaramond-Medium", size: 13))
                    .foregroundColor(day == "Вс" ? theme.accent : theme.muted)
                    .frame(maxWidth: .infinity)
            }
        }
    }
    
    // MARK: - Calendar Grid
    
    private var calendarGrid: some View {
        let totalCells = firstWeekday + daysInMonth
        let rows = (totalCells + 6) / 7
        
        return VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let index = row * 7 + col
                        let day = index - firstWeekday + 1
                        
                        if day >= 1 && day <= daysInMonth {
                            dayCell(day: day, isSunday: col == 6)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                    }
                }
            }
        }
    }
    
    private func dayCell(day: Int, isSunday: Bool) -> some View {
        let isSelected = tabState.selectedCalendarDay == day
        let today = isToday(day)
        let dayData = calendarService.getCachedDay(year: year, month: month, day: day)
        let isFasting = dayData.map { $0.fastingLevel != .none } ?? false
        
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if tabState.selectedCalendarDay == day {
                    tabState.selectedCalendarDay = nil
                } else {
                    tabState.selectedCalendarDay = day
                    // Ensure data is loaded
                    if dayData == nil {
                        let cal = Calendar.current
                        if let date = cal.date(from: DateComponents(year: year, month: month, day: day)) {
                            Task { await calendarService.fetchDay(date: date) }
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(day)")
                    .font(.custom(
                        today ? "CormorantGaramond-Bold" : "CormorantGaramond-Regular",
                        size: 16
                    ))
                    .foregroundColor(
                        isSelected ? .white :
                        today ? theme.accent :
                        isSunday ? theme.accent.opacity(0.7) :
                        theme.text
                    )
                
                // Fasting dot
                Circle()
                    .fill(isFasting ? theme.fastText : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected ? theme.accent :
                        today ? theme.todayBg :
                        .clear
                    )
            )
        }
        .accessibilityLabel("\(day) \(monthNames[month - 1])")
        .accessibilityAddTraits(today ? .isSelected : [])
    }
    
    // MARK: - Day Detail Card
    
    private func dayDetailCard(day: Int, data: LiturgicalDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(day) \(monthNames[month - 1])")
                    .font(.custom("CormorantGaramond-SemiBold", size: 18))
                    .foregroundColor(theme.text)
                
                Spacer()
                
                if let tone = data.tone {
                    Text("Глас \(tone)")
                        .font(.custom("CormorantGaramond-Medium", size: 13))
                        .foregroundColor(theme.muted)
                }
            }
            
            if !data.weekName.isEmpty {
                Text(data.weekName)
                    .font(.custom("CormorantGaramond-Regular", size: 14))
                    .foregroundColor(theme.muted)
            }
            
            if data.fastingLevel != .none {
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.fastText)
                        .frame(width: 6, height: 6)
                    Text(data.fastingName.isEmpty ? data.fastingLevel.displayName : data.fastingName)
                        .font(.custom("CormorantGaramond-Medium", size: 13))
                        .foregroundColor(theme.fastText)
                }
            }
            
            if !data.apostolReadings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Апостол")
                        .font(.custom("CormorantGaramond-Medium", size: 12))
                        .foregroundColor(theme.muted)
                        .textCase(.uppercase)
                    ForEach(data.apostolReadings, id: \.self) { r in
                        Text(r)
                            .font(.custom("CormorantGaramond-Regular", size: 15))
                            .foregroundColor(theme.accent)
                    }
                }
            }
            
            if !data.gospelReadings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Евангелие")
                        .font(.custom("CormorantGaramond-Medium", size: 12))
                        .foregroundColor(theme.muted)
                        .textCase(.uppercase)
                    ForEach(data.gospelReadings, id: \.self) { r in
                        Text(r)
                            .font(.custom("CormorantGaramond-Regular", size: 15))
                            .foregroundColor(theme.accent)
                    }
                }
            }
            
            if !data.saints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(data.saints.prefix(3), id: \.self) { saint in
                        Text("☦ \(saint)")
                            .font(.custom("CormorantGaramond-Regular", size: 14))
                            .foregroundColor(theme.text)
                            .lineLimit(1)
                    }
                    if data.saints.count > 3 {
                        Text("и ещё \(data.saints.count - 3)...")
                            .font(.custom("CormorantGaramond-Regular", size: 13))
                            .foregroundColor(theme.muted)
                    }
                }
            }
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    // MARK: - Navigation
    
    private func prevMonth() {
        withAnimation(.easeInOut(duration: 0.2)) {
            tabState.selectedCalendarDay = nil
            if month == 1 {
                tabState.calendarMonth = 12
                tabState.calendarYear = year - 1
            } else {
                tabState.calendarMonth = month - 1
            }
        }
    }
    
    private func nextMonth() {
        withAnimation(.easeInOut(duration: 0.2)) {
            tabState.selectedCalendarDay = nil
            if month == 12 {
                tabState.calendarMonth = 1
                tabState.calendarYear = year + 1
            } else {
                tabState.calendarMonth = month + 1
            }
        }
    }
}

#Preview {
    CalendarView()
        .environmentObject(AppState())
        .environmentObject(AzbykaCalendarService())
        .environmentObject(TabNavigationState(tab: .calendar))
}
