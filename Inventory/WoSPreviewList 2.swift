import SwiftUI
import CoreData

struct WoSPreviewList: View {
    @Environment(\.managedObjectContext) private var ctx

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inventario")
                .font(.headline)

            StockListView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
