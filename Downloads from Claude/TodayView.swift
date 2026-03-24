import SwiftUI

struct TodayView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var calendarService: AzbykaCalendarService
    @EnvironmentObject var tabState: TabNavigationState
    
    private let theme = OrthodoxTheme.shared
    
    private var todayData: LiturgicalDay? {
        calendarService.todayData
    }
    
    private var dateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy г."
        return f.string(from: Date())
    }
    
    private var dayOfWeekString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE"
        let s = f.string(from: Date())
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    
    var body: some View {
        NavigationStack(path: $tabState.navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    headerSection
                    
                    if calendarService.isLoading && todayData == nil {
                        loadingView
                    } else if let day = todayData {
                        // Week / liturgical period
                        if !day.weekName.isEmpty {
                            periodCard(day.weekName)
                        }
                        
                        // Fasting
                        if day.fastingLevel != .none {
                            fastingBadge(day)
                        }
                        
                        // Readings
                        if !day.apostolReadings.isEmpty || !day.gospelReadings.isEmpty {
                            readingsCard(day)
                        }
                        
                        // Saints
                        if !day.saints.isEmpty {
                            saintsCard(day.saints)
                        }
                        
                        // Holidays
                        if !day.holidays.isEmpty {
                            holidaysCard(day.holidays)
                        }
                    } else if let error = calendarService.errorMessage {
                        errorView(error)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .background(Color(hex: "FAF8F5"))
            .refreshable {
                await calendarService.fetchToday()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayOfWeekString)
                .font(.custom("CormorantGaramond-SemiBold", size: 28))
                .foregroundColor(Color(hex: "2C2418"))
            Text(dateString)
                .font(.custom("CormorantGaramond-Regular", size: 16))
                .foregroundColor(Color(hex: "9E9484"))
        }
        .padding(.top, 60)
    }
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color(hex: "8B6914"))
            Text("Загружаем данные с Азбуки веры...")
                .font(.custom("CormorantGaramond-Regular", size: 15))
                .foregroundColor(Color(hex: "9E9484"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private func periodCard(_ period: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .foregroundColor(Color(hex: "8B6914"))
                .font(.system(size: 16))
            Text(period)
                .font(.custom("CormorantGaramond-Medium", size: 15))
                .foregroundColor(Color(hex: "2C2418"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "F5F0E6"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    private func fastingBadge(_ day: LiturgicalDay) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: "A68B5B"))
                .frame(width: 8, height: 8)
            Text(day.fastingName.isEmpty ? day.fastingLevel.displayName : day.fastingName)
                .font(.custom("CormorantGaramond-Medium", size: 14))
                .foregroundColor(Color(hex: "A68B5B"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(hex: "F0EBE3"))
        .clipShape(Capsule())
    }
    
    private func readingsCard(_ day: LiturgicalDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Чтения дня")
                .font(.custom("CormorantGaramond-SemiBold", size: 18))
                .foregroundColor(Color(hex: "2C2418"))
            
            if !day.apostolReadings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Апостол")
                        .font(.custom("CormorantGaramond-Medium", size: 13))
                        .foregroundColor(Color(hex: "9E9484"))
                        .textCase(.uppercase)
                    
                    ForEach(day.apostolReadings, id: \.self) { reading in
                        Text(reading)
                            .font(.custom("CormorantGaramond-Regular", size: 16))
                            .foregroundColor(Color(hex: "8B6914"))
                    }
                }
            }
            
            if !day.gospelReadings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Евангелие")
                        .font(.custom("CormorantGaramond-Medium", size: 13))
                        .foregroundColor(Color(hex: "9E9484"))
                        .textCase(.uppercase)
                    
                    ForEach(day.gospelReadings, id: \.self) { reading in
                        Text(reading)
                            .font(.custom("CormorantGaramond-Regular", size: 16))
                            .foregroundColor(Color(hex: "8B6914"))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private func saintsCard(_ saints: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Память святых")
                .font(.custom("CormorantGaramond-SemiBold", size: 18))
                .foregroundColor(Color(hex: "2C2418"))
            
            ForEach(saints.prefix(5), id: \.self) { saint in
                HStack(alignment: .top, spacing: 8) {
                    Text("☦")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "8B6914"))
                        .padding(.top, 2)
                    Text(saint)
                        .font(.custom("CormorantGaramond-Regular", size: 15))
                        .foregroundColor(Color(hex: "2C2418"))
                        .lineLimit(2)
                }
            }
            
            if saints.count > 5 {
                Text("и ещё \(saints.count - 5)...")
                    .font(.custom("CormorantGaramond-Regular", size: 14))
                    .foregroundColor(Color(hex: "9E9484"))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private func holidaysCard(_ holidays: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Праздники")
                .font(.custom("CormorantGaramond-SemiBold", size: 18))
                .foregroundColor(Color(hex: "2C2418"))
            
            ForEach(holidays, id: \.self) { holiday in
                Text(holiday)
                    .font(.custom("CormorantGaramond-Medium", size: 16))
                    .foregroundColor(Color(hex: "8B6914"))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "F5F0E6"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 32))
                .foregroundColor(Color(hex: "9E9484"))
            Text(message)
                .font(.custom("CormorantGaramond-Regular", size: 15))
                .foregroundColor(Color(hex: "9E9484"))
                .multilineTextAlignment(.center)
            Button("Повторить") {
                Task { await calendarService.fetchToday() }
            }
            .font(.custom("CormorantGaramond-Medium", size: 15))
            .foregroundColor(Color(hex: "8B6914"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Theme Helper

struct OrthodoxTheme {
    static let shared = OrthodoxTheme()
    
    let background = Color(hex: "FAF8F5")
    let card = Color.white
    let text = Color(hex: "2C2418")
    let muted = Color(hex: "9E9484")
    let accent = Color(hex: "8B6914")
    let border = Color(hex: "EDE8E0")
    let fastBg = Color(hex: "F0EBE3")
    let fastText = Color(hex: "A68B5B")
    let todayBg = Color(hex: "F5F0E6")
}

#Preview {
    TodayView()
        .environmentObject(AppState())
        .environmentObject(AzbykaCalendarService())
        .environmentObject(TabNavigationState(tab: .today))
}
