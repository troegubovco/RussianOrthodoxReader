//
//  ContentsSheet.swift
//  RussianOrthodoxReaderWatch
//
//  «Содержание»: для последования из нескольких молитв — по одной строке на
//  молитву (переход на её первый фрагмент); для одной молитвы с указаниями —
//  по строке на указание; иначе — по строке на «Часть N».
//

import SwiftUI

struct ContentsSheet: View {
    let fragments: [Fragment]
    let currentIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private var isMultiPrayer: Bool {
        Set(fragments.map(\.prayerIndex)).count > 1
    }

    private var rows: [Fragment] {
        isMultiPrayer ? fragments.filter(\.showsTitle) : fragments
    }

    private func isCurrent(_ fragment: Fragment) -> Bool {
        guard fragments.indices.contains(currentIndex) else { return false }
        let current = fragments[currentIndex]
        return isMultiPrayer ? fragment.prayerIndex == current.prayerIndex : fragment.id == currentIndex
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { fragment in
                    Button {
                        onSelect(fragment.id)
                        dismiss()
                    } label: {
                        HStack {
                            Text(fragment.label)
                                .font(WatchTheme.chrome(15))
                                .foregroundStyle(WatchTheme.body)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if isCurrent(fragment) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(WatchTheme.accent)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("Содержание")
        }
    }
}
