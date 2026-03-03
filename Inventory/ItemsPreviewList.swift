import SwiftUI
import CoreData

struct ItemsPreviewList: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "sku", ascending: true)],
        animation: .default)
    private var items: FetchedResults<NSManagedObject>

    init() {
        _items = FetchRequest(
            entity: NSEntityDescription.entity(forEntityName: "Item", in: PersistenceController.shared.container.viewContext)!,
            sortDescriptors: [NSSortDescriptor(key: "sku", ascending: true)],
            predicate: nil,
            animation: .default
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SKUs (demo)").font(.headline)
            if items.isEmpty {
                Text("Sin datos").foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.objectID) { obj in
                    HStack {
                        Text(obj.value(forKey: "sku") as? String ?? "—")
                            .font(.body.monospaced())
                        Text(obj.value(forKey: "name") as? String ?? "")
                            .font(.body)
                        Spacer()
                        Text((obj.value(forKey: "unit") as? String ?? "").uppercased())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }
}
