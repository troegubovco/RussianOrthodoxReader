import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var calendarService: AzbykaCalendarService
    @EnvironmentObject var tabState: TabNavigationState
    
    @State private var showingAPIKeySheet = false
    @State private var apiKeyInput = ""
    
    private let theme = OrthodoxTheme.shared
    
    var body: some View {
        NavigationStack(path: $tabState.navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Настройки")
                        .font(.custom("CormorantGaramond-SemiBold", size: 28))
                        .foregroundColor(theme.text)
                        .padding(.top, 60)
                    
                    // Font size
                    fontSizeSection
                    
                    // Notifications
                    notificationSection
                    
                    // API Configuration
                    apiSection
                    
                    // About
                    aboutSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .background(Color(hex: "FAF8F5"))
            .sheet(isPresented: $showingAPIKeySheet) {
                apiKeySheet
            }
        }
    }
    
    // MARK: - Font Size
    
    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Размер шрифта")
                .font(.custom("CormorantGaramond-Medium", size: 16))
                .foregroundColor(theme.text)
            
            HStack {
                Text("А")
                    .font(.custom("CormorantGaramond-Regular", size: 14))
                    .foregroundColor(theme.muted)
                
                Slider(value: $appState.fontSize, in: 14...28, step: 1)
                    .tint(theme.accent)
                
                Text("А")
                    .font(.custom("CormorantGaramond-Regular", size: 24))
                    .foregroundColor(theme.muted)
            }
            
            Text("Пример текста Синодального перевода")
                .font(.custom("CormorantGaramond-Regular", size: appState.fontSize))
                .foregroundColor(theme.text)
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    // MARK: - Notifications
    
    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsToggle(
                title: "Уведомления",
                subtitle: "Напоминание о чтениях дня",
                isOn: $appState.notificationsEnabled
            )
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    // MARK: - API Section
    
    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Источник календаря")
                .font(.custom("CormorantGaramond-Medium", size: 16))
                .foregroundColor(theme.text)
            
            HStack(spacing: 8) {
                Image(systemName: calendarService.apiKey != nil ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(calendarService.apiKey != nil ? .green : theme.muted)
                    .font(.system(size: 16))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Азбука веры API")
                        .font(.custom("CormorantGaramond-Medium", size: 15))
                        .foregroundColor(theme.text)
                    
                    Text(calendarService.apiKey != nil
                         ? "Ключ API настроен"
                         : "Используется виджет (ограниченные данные)")
                        .font(.custom("CormorantGaramond-Regular", size: 13))
                        .foregroundColor(theme.muted)
                }
                
                Spacer()
            }
            
            Button {
                apiKeyInput = calendarService.apiKey ?? ""
                showingAPIKeySheet = true
            } label: {
                Text(calendarService.apiKey != nil ? "Изменить ключ" : "Добавить ключ API")
                    .font(.custom("CormorantGaramond-Medium", size: 15))
                    .foregroundColor(theme.accent)
            }
            
            Text("Зарегистрируйтесь на azbyka.ru/days/register/userapi для получения ключа API.")
                .font(.custom("CormorantGaramond-Regular", size: 12))
                .foregroundColor(theme.muted)
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    // MARK: - About
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("О приложении")
                .font(.custom("CormorantGaramond-Medium", size: 16))
                .foregroundColor(theme.text)
            
            Text("Православное Чтение v0.2")
                .font(.custom("CormorantGaramond-Regular", size: 14))
                .foregroundColor(theme.muted)
            Text("Open Source — MIT License")
                .font(.custom("CormorantGaramond-Regular", size: 14))
                .foregroundColor(theme.muted)
            Text("Синодальный перевод — общественное достояние")
                .font(.custom("CormorantGaramond-Regular", size: 14))
                .foregroundColor(theme.muted)
            Text("Календарь — Азбука веры (azbyka.ru)")
                .font(.custom("CormorantGaramond-Regular", size: 14))
                .foregroundColor(theme.muted)
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    // MARK: - API Key Sheet
    
    private var apiKeySheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Чтобы получить полный доступ к данным календаря (чтения, пост, святые), зарегистрируйтесь на Азбуке веры.")
                    .font(.custom("CormorantGaramond-Regular", size: 15))
                    .foregroundColor(theme.text)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Как получить ключ:")
                        .font(.custom("CormorantGaramond-Medium", size: 15))
                        .foregroundColor(theme.text)
                    
                    Text("1. Откройте azbyka.ru/days/register/userapi")
                        .font(.custom("CormorantGaramond-Regular", size: 14))
                        .foregroundColor(theme.muted)
                    Text("2. Заполните форму регистрации")
                        .font(.custom("CormorantGaramond-Regular", size: 14))
                        .foregroundColor(theme.muted)
                    Text("3. Подтвердите email")
                        .font(.custom("CormorantGaramond-Regular", size: 14))
                        .foregroundColor(theme.muted)
                    Text("4. Дождитесь одобрения администратора")
                        .font(.custom("CormorantGaramond-Regular", size: 14))
                        .foregroundColor(theme.muted)
                }
                
                TextField("Ключ API", text: $apiKeyInput)
                    .font(.custom("CormorantGaramond-Regular", size: 16))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("Ключ API Азбуки веры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        showingAPIKeySheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        calendarService.apiKey = apiKeyInput.isEmpty ? nil : apiKeyInput
                        showingAPIKeySheet = false
                        // Refetch today with the new key
                        Task { await calendarService.fetchToday() }
                    }
                    .font(.custom("CormorantGaramond-Medium", size: 16))
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    // MARK: - Helpers
    
    private func settingsToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.custom("CormorantGaramond-Medium", size: 16))
                    .foregroundColor(theme.text)
                Text(subtitle)
                    .font(.custom("CormorantGaramond-Regular", size: 13))
                    .foregroundColor(theme.muted)
            }
        }
        .tint(theme.accent)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(AzbykaCalendarService())
        .environmentObject(TabNavigationState(tab: .settings))
}
