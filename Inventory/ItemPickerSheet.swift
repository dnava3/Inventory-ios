import SwiftUI
import CoreData

struct ItemPickerSheet: View {
    let items: [NSManagedObject]
    @Binding var selected: NSManagedObject?
    @Binding var skuText: String
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var filtered: [NSManagedObject] {
        guard !query.isEmpty else { return items }
        return items.filter { it in
            let sku = (it.value(forKey: "sku") as? String)?.lowercased() ?? ""
            let name = (it.value(forKey: "name") as? String)?.lowercased() ?? ""
            return sku.contains(query.lowercased()) || name.contains(query.lowercased())
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.objectID) { it in
                Button {
                    selected = it
                    skuText = (it.value(forKey: "sku") as? String) ?? ""
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((it.value(forKey: "name") as? String) ?? "—")
                        Text((it.value(forKey: "sku") as? String) ?? "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Buscar SKU o nombre")
            .navigationTitle("Selecciona SKU")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
