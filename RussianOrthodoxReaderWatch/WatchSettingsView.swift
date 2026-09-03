//
//  WatchSettingsView.swift
//  RussianOrthodoxReaderWatch
//
//  Настройки чтения на часах: размер текста, язык (ЦС/русский), ударения.
//

import SwiftUI

struct WatchSettingsView: View {
    @AppStorage("watch.textStep") private var textStepRaw = WatchTheme.TextStep.regular.rawValue
    @AppStorage("watch.prayerLanguage") private var languageRaw = PrayerLanguage.churchSlavonic.rawValue
    @AppStorage("watch.showStress") private var showStress = true
    @AppStorage(PrayersRepository.feminineFormsKey) private var feminineForms = false

    var body: some View {
        List {
            Section("Размер текста") {
                ForEach(WatchTheme.TextStep.allCases, id: \.rawValue) { step in
                    Button {
                        textStepRaw = step.rawValue
                    } label: {
                        HStack {
                            Text("Аа")
                                .font(WatchTheme.serif(step.basePt))
                                .frame(width: 28, alignment: .leading)
                            Text(step.label)
                            Spacer()
                            if step.rawValue == textStepRaw {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(WatchTheme.accent)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section("Язык") {
                WatchSegmentedControl(
                    segments: PrayerLanguage.allCases.map { ($0.rawValue, $0.shortTitle) },
                    selection: $languageRaw
                )
            }

            Section {
                Toggle("Ударения", isOn: $showStress)
                Toggle("Женская форма", isOn: $feminineForms)
            }

            Section {
                Text("Чтобы экран не гас: Настройки → Основные → Возврат к циферблату → Синодал → После 1 часа")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.muted)
            }
        }
        .navigationTitle("Настройки")
    }
}
