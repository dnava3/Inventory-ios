import SwiftUI
import CoreData

struct WosPreviewListView: View {
    @Environment(\.managedObjectContext) private var ctx

    @State private var items: [NSManagedObject] = []
    @State private var query: String = ""
    @State private var onlyCritical: Bool = true
    @State private var errorText: String?

    @State private var showShare: Bool = false
    @State private var exportURL: URL?

    private let safetyWeeks: Double = 1.0
    private let redThreshold: Double = 1.5
    private let amberThreshold: Double = 3.0
    private struct Row: Identifiable {
        let id: NSManagedObjectID
        let sku: String
        let name: String
        let unit: String
        let minStock: Double
        let reorderPoint: Double
        let leadTimeDays: Int
        let stock: Double
        let avgWeekly: Double
        let wos: Double?
        let suggested: Double
        let isCritical: Bool
    }

    private var rows: [Row] {
        let lower = query.lowercased()
        let filtered = items.filter { it in
            guard !query.isEmpty else { return true }
            let sku = (it.value(forKey: "sku") as? String)?.lowercased() ?? ""
            let name = (it.value(forKey: "name") as? String)?.lowercased() ?? ""
            return sku.contains(lower) || name.contains(lower)
        }
        .map { it -> Row in
            let sku = (it.value(forKey: "sku") as? String) ?? ""
            let name = (it.value(forKey: "name") as? String) ?? ""
            let unit = (it.value(forKey: "unit") as? String) ?? ""
            let minStock = (it.value(forKey: "minStock") as? Double) ?? 0
            let reorderPoint = (it.value(forKey: "reorderPoint") as? Double) ?? 0
            let leadTimeDays = Int((it.value(forKey: "leadTimeDays") as? Int16) ?? 0)

            let stock = StockService.currentStock(for: sku, in: ctx)
            let avg = ConsumptionService.averageWeeklyConsumption(for: sku, weeks: 4, asOf: Date(), in: ctx)
            let w = WoSService.wos(for: sku, in: ctx)

            let leadWeeks = Double(leadTimeDays) / 7.0
            let target: Double = {
                if avg > 0 {
                    return avg * (leadWeeks + safetyWeeks)
                } else if reorderPoint > 0 {
                    return reorderPoint
                } else {
                    return minStock
                }
            }()
            let suggested = max(0, target - stock)

            let criticalByWos = (w ?? Double.greatestFiniteMagnitude) < redThreshold
            let criticalByMin = stock < minStock
            let criticalByROP = reorderPoint > 0 ? (stock < reorderPoint) : false
            let isCritical = criticalByWos || criticalByMin || criticalByROP

            return Row(
                id: it.objectID,
                sku: sku,
                name: name,
                unit: unit,
                minStock: minStock,
                reorderPoint: reorderPoint,
                leadTimeDays: leadTimeDays,
                stock: stock,
                avgWeekly: avg,
                wos: w,
                suggested: suggested,
                isCritical: isCritical
            )
        }
        .filter { onlyCritical ? $0.isCritical : true }
        .sorted { a, b in
            switch (a.wos, b.wos) {
            case let (l?, r?):
                if l == r {
                    let aGap = a.stock - a.minStock
                    let bGap = b.stock - b.minStock
                    if aGap == bGap { return a.sku < b.sku }
                    return aGap < bGap
                }
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let aGap = a.stock - a.minStock
                let bGap = b.stock - b.minStock
                if aGap == bGap { return a.sku < b.sku }
                return aGap < bGap
            }
        }
        return filtered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Reabasto sugerido").font(.title3.weight(.semibold)); Spacer() }
            if let err = errorText { Text(err).foregroundStyle(.red).font(.caption) }

            HStack(spacing: 12) {
                TextField("Buscar SKU o nombre", text: $query)
                    .textFieldStyle(.roundedBorder)
                Toggle("Solo críticos", isOn: $onlyCritical)
            }

            if rows.isEmpty {
                Text(onlyCritical ? "Sin SKUs críticos" : "Sin SKUs")
                    .foregroundStyle(.secondary)
            } else {
                List(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Circle().fill(color(for: row.wos, minGap: row.stock - row.minStock)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.sku) • \(row.name)").font(.subheadline.weight(.semibold))
                            Text("Stock: \(fmt(row.stock)) \(row.unit)  •  Cons/sem: \(fmt(row.avgWeekly))  •  Min: \(fmt(row.minStock))  •  ROP: \(fmt(row.reorderPoint))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Sugerido")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(fmt(row.suggested))
                                .font(.headline.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { exportCSV() } label: { Image(systemName: "square.and.arrow.up") } } }
        .navigationTitle("Reabasto")
        .onAppear(perform: loadItems)
        .sheet(isPresented: $showShare) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
    }


    private func loadItems() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "Item")
        req.sortDescriptors = [NSSortDescriptor(key: "sku", ascending: true)]
        do { items = try ctx.fetch(req) }
        catch { errorText = "No se pudo cargar catálogo de SKUs: \(error.localizedDescription)" }
    }


    private func exportCSV() {
        let headers = ["SKU","Nombre","UM","Stock","ConsumoSem","WoS","Sugerido","MinStock","ReorderPoint","LeadTimeDays"]
        let lines: [String] = [headers.joined(separator: ",")] + rows.map { r in
            let wosText = r.wos.map { String(format: "%.2f", $0) } ?? ""
            return [r.sku, r.name.replacingOccurrences(of: ",", with: ";"), r.unit,
                    fmtRaw(r.stock), fmtRaw(r.avgWeekly), wosText, fmtRaw(r.suggested), fmtRaw(r.minStock), fmtRaw(r.reorderPoint), String(r.leadTimeDays)
            ].joined(separator: ",")
        }
        let csv = lines.joined(separator: "\n")
        do {
            let url = try writeTempCSV(named: "reabasto.csv", contents: csv)
            exportURL = url
            showShare = true
        } catch {
            errorText = "No se pudo generar CSV: \(error.localizedDescription)"
        }
    }

    private func writeTempCSV(named: String, contents: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent(named)
        try contents.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }


    private func wosText(_ w: Double?) -> String { guard let w = w else { return "—" }; return w < 10 ? String(format: "%.2f", w) : String(format: "%.0f", w) }
    private func fmt(_ v: Double) -> String { if v == floor(v) { return "\(Int(v))" }; return String(format: "%.2f", v) }
    private func fmtRaw(_ v: Double) -> String { String(format: "%.2f", v) }

    private func color(for w: Double?, minGap: Double) -> Color {
        if minGap < 0 { return .red }
        guard let w = w else { return .gray }
        if w < redThreshold { return .red }
        if w < amberThreshold { return .orange }
        return .green
    }
}


struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
