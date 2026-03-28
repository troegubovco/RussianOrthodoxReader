import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    @State private var showAPIKeySheet = false
    @State private var apiKeyDraft = ""
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Настройки")
                        .font(AppFont.medium(typ.title))
                        .foregroundColor(theme.text)
                        .padding(.top, isLandscape ? 12 : 8)

                    // Notifications
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Уведомления о чтениях",
                            subtitle: "Напоминание накануне",
                            isOn: $appState.notificationsEnabled
                        )
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $appState.iCloudSyncEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Синхронизация через iCloud")
                                    .font(AppFont.regular(typ.subheadline))
                                    .foregroundColor(theme.text)

                                Text("Синхронизирует только место чтения между вашими устройствами.")
                                    .font(AppFont.regular(typ.caption))
                                    .foregroundColor(theme.muted)
                            }
                        }
                        .tint(theme.accent)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(appState.readingSyncStatusTitle)
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.text)

                            Text(appState.readingSyncStatusDetail)
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.muted)
                        }

                        Text("В iCloud сохраняются только книга, глава, стих и время последнего обновления. Данные находятся в вашей приватной базе CloudKit.")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()

                    // Reading preferences
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Размер шрифта")
                                .font(AppFont.regular(typ.subheadline))
                                .foregroundColor(theme.text)

                            HStack(spacing: 16) {
                                Button {
                                    appState.fontSize = AppState.clampFontSize(appState.fontSize - 2)
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 18, weight: .semibold))
                                        .frame(width: 36, height: 36)
                                        .background(theme.card)
                                        .overlay(
                                            Circle().stroke(theme.border, lineWidth: 1)
                                        )
                                        .clipShape(Circle())
                                }
                                .foregroundColor(theme.text)
                                .accessibilityLabel("Уменьшить")

                                VStack(spacing: 2) {
                                    Text("Аа")
                                        .font(AppFont.regular(CGFloat(appState.fontSize)))
                                        .foregroundColor(theme.text)
                                    Text("\(Int(appState.fontSize)) пт")
                                        .font(AppFont.regular(typ.caption))
                                        .foregroundColor(theme.muted)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Текущий размер шрифта \(Int(appState.fontSize)) пунктов")

                                Button {
                                    appState.fontSize = AppState.clampFontSize(appState.fontSize + 2)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .semibold))
                                        .frame(width: 36, height: 36)
                                        .background(theme.card)
                                        .overlay(
                                            Circle().stroke(theme.border, lineWidth: 1)
                                        )
                                        .clipShape(Circle())
                                }
                                .foregroundColor(theme.text)
                                .accessibilityLabel("Увеличить")
                            }
                            .accessibilityElement(children: .contain)

                            Text("Размер шрифта влияет на весь текст в приложении")
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.muted)

                            Divider()
                                .padding(.vertical, 4)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Шрифт")
                                    .font(AppFont.regular(typ.subheadline))
                                    .foregroundColor(theme.text)

                                Picker("Шрифт", selection: $appState.fontFamily) {
                                    ForEach(AppFontFamily.allCases) { family in
                                        Text(family.title).tag(family)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .tint(theme.accent)
                                .accessibilityLabel("Выбор шрифта")
                            }
                        }
                        .padding(20)
                    }
                    .cardStyle()

                    // Calendar source (Azbyka API)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Источник календаря")
                            .font(AppFont.regular(typ.subheadline))
                            .foregroundColor(theme.text)

                        let hasKey = !(UserDefaults.standard.string(forKey: "azbyka_api_key") ?? "").isEmpty
                        HStack(spacing: 8) {
                            Circle()
                                .fill(hasKey ? Color.green : theme.muted)
                                .frame(width: 8, height: 8)
                            Text(hasKey ? "Полный API (чтения, пост, глас)" : "Публичная страница Azbyka (чтения и память)")
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.text)
                        }

                        Button {
                            apiKeyDraft = UserDefaults.standard.string(forKey: "azbyka_api_key") ?? ""
                            showAPIKeySheet = true
                        } label: {
                            Text(hasKey ? "Изменить ключ API" : "Добавить ключ API")
                                .font(AppFont.regular(typ.footnote))
                                .foregroundColor(theme.accent)
                        }

                        Text("Без ключа приложение читает публичную страницу Azbyka. Ключ нужен только для полного API, если он у вас есть.")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
                    .sheet(isPresented: $showAPIKeySheet) {
                        apiKeySheet
                    }

                    // About
                    VStack(alignment: .leading, spacing: 8) {
                        Text("О приложении")
                            .font(AppFont.regular(typ.subheadline))
                            .foregroundColor(theme.text)

                        Group {
                            Text("Православное Чтение v1.0")
                            Text("Открытый исходный код — лицензия MIT")
                            Text("Синодальный перевод — общественное достояние")
                            Text("Словарь — Библейский словарь Нюстрема (1874)")
                            Text("Церковнослав. словарь — прот. Г. Дьяченко (1900)")
                            Text("Словоформы — OpenCorpora (opencorpora.org), CC BY-SA")
                        }
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()

                    // Reset prayer
                    Button {
                        UserDefaults.standard.removeObject(forKey: "lastPrayerDate")
                        appState.checkPrayerStatus()
                    } label: {
                        Text("Сбросить молитву дня (для тестирования)")
                            .font(AppFont.regular(typ.footnote))
                            .foregroundColor(theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableContentWidth()
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var apiKeySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ключ API", text: $apiKeyDraft)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Ключ API Азбука.ру")
                } footer: {
                    Text("Зарегистрируйтесь на azbyka.ru/days/register/userapi и дождитесь одобрения. Затем введите полученный ключ.")
                }
            }
            .navigationTitle("Ключ API")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        showAPIKeySheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: "azbyka_api_key")
                        showAPIKeySheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Settings Toggle Row

struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.regular(typ.subheadline))
                    .foregroundColor(theme.text)

                Text(subtitle)
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .tint(theme.accent)
                .labelsHidden()
        }
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityValue(isOn ? "Включено" : "Выключено")
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
