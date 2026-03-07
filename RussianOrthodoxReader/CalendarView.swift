import SwiftUI

struct CalendarView: View {
    @State private var viewYear: Int
    @State private var viewMonth: Int  // 0-indexed
    @State private var selectedDay: Int? = nil
    
    let theme = OrthodoxColorsFallback()
    private let daysOfWeek = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
    
    init() {
        let cal = Calendar.current
        let now = Date()
        _viewYear = State(initialValue: cal.component(.year, from: now))
        _viewMonth = State(initialValue: cal.component(.month, from: now) - 1)
    }
    
    private var readings: [Int: LiturgicalDay] {
        LiturgicalCalendar.readings(year: viewYear, month: viewMonth)
    }
    
    private var firstWeekdayOffset: Int {
        let date = Calendar.current.date(from: DateComponents(year: viewYear, month: viewMonth + 1, day: 1))!
        let dow = Calendar.current.component(.weekday, from: date) // 1=Sun, 2=Mon, ...
        return (dow + 5) % 7  // Convert to Mon=0
    }
    
    private var daysInMonth: Int {
        Calendar.current.range(of: .day, in: .month,
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Календарь")
                    .font(AppFont.medium(28))
                    .foregroundColor(theme.text)
                    .padding(.top, 60)
                
                // Month navigation
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
                        .font(AppFont.medium(20))
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
                
                // Day-of-week headers
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 2) {
                    ForEach(daysOfWeek, id: \.self) { day in
                        Text(day)
                            .font(AppFont.semiBold(13))
                            .foregroundColor(day == "Вс" ? theme.accent : theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                
                // Calendar grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 2) {
                    // Empty cells for offset
                    ForEach(0..<firstWeekdayOffset, id: \.self) { _ in
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                    
                    // Day cells
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
                
                // Selected day detail
                if let day = selectedDay, let info = readings[day] {
                    DayDetailCard(day: day, month: viewMonth, info: info)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 120)
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

// MARK: - Calendar Day Cell

struct CalendarDayCell: View {
    let day: Int
    let reading: LiturgicalDay?
    let isToday: Bool
    let isSelected: Bool
    let action: () -> Void
    
    let theme = OrthodoxColorsFallback()
    
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.accent : isToday ? theme.todayHighlight : theme.card)
                
                VStack(spacing: 2) {
                    Text("\(day)")
                        .font(AppFont.regular(16))
                        .fontWeight(isToday || isSelected ? .bold : .regular)
                        .foregroundColor(
                            isSelected ? .white :
                            isToday ? theme.accent :
                            reading?.isSunday == true ? theme.accent :
                            theme.text
                        )
                    
                    if let r = reading, r.isFastDay && !isSelected {
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

// MARK: - Day Detail Card

struct DayDetailCard: View {
    let day: Int
    let month: Int
    let info: LiturgicalDay
    
    let theme = OrthodoxColorsFallback()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("\(day) \(LiturgicalCalendar.monthNames[month])")
                    .sectionHeader()
                
                Spacer()
                
                if info.isFastDay {
                    Text(info.fastingLevel.rawValue)
                        .font(AppFont.regular(12))
                        .foregroundColor(theme.fastText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.fastBackground))
                }
            }
            
            // Saint
            Text(info.saintOfDay)
                .font(AppFont.regular(16))
                .foregroundColor(theme.text)
                .lineSpacing(4)
            
            Divider()
                .background(theme.border)
            
            // Readings
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Апостол:")
                        .font(AppFont.regular(13))
                        .foregroundColor(theme.muted)
                    Text(info.apostolReading)
                        .font(AppFont.medium(16))
                        .foregroundColor(theme.text)
                }
                
                HStack(spacing: 8) {
                    Text("Евангелие:")
                        .font(AppFont.regular(13))
                        .foregroundColor(theme.muted)
                    Text(info.gospelReading)
                        .font(AppFont.medium(16))
                        .foregroundColor(theme.text)
                }
                
                if let tone = info.tone {
                    HStack(spacing: 8) {
                        Text("Глас:")
                            .font(AppFont.regular(13))
                            .foregroundColor(theme.muted)
                        Text("\(tone)")
                            .font(AppFont.semiBold(16))
                            .foregroundColor(theme.accent)
                    }
                }
            }
        }
        .padding(24)
        .cardStyle()
    }
}

#Preview {
    CalendarView()
        .environmentObject(AppState())
}
