// Assume this is your view file (replace with the actual filename)
import SwiftUI

struct HypotheticalGridView: View {
    let items: [SomeItem]  // Your data model

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
            ForEach(items) { item in
                // Use unique ID from model (e.g., item.id) instead of index or constant
                Text(item.name)
                    .id(item.id)  // Ensures uniqueness
            }
        }
    }
}

// In your model
struct SomeItem: Identifiable {
    let id = UUID()  // Or a unique property
    let name: String
}
