import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
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
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
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
