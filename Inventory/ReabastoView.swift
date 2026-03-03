import SwiftUI
import CoreData

struct ReabastoView: View {
    @Environment(\.managedObjectContext) private var ctx

    @State private var items: [NSManagedObject] = []
    @State private var forecastRates: [String: Double] = [:]
    @State private var targetWeeks: Double = 4
    @State private var qtyOverrides: [String: Double] = [:]
    @State private var etaOverrides: [String: Date] = [:]
    @State private var include: [String: Bool] = [:]
    @State private var showShare = false
    @State private var exportURL: URL? = nil

    var body: some View {
        VStack(spacing: 12) {
            GlassCard {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reabasto")
                            .font(.title2.weight(.semibold))
                        Text("Sugerencias a partir de demanda, LT, POs y BOs")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        Text("Semanas objetivo")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Stepper(value: $targetWeeks, in: 1...12, step: 1) {
                            Text("\(Int(targetWeeks)) sem")
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }
            }

            GlassCard {
                List {
                    ForEach(rows) { r in
                        ReabastoRow(
                            row: r,
                            qty: Binding(
                                get: { qtyOverrides[r.sku] ?? r.suggested },
                                set: { qtyOverrides[r.sku] = $0 }
                            ),
                            eta: Binding(
                                get: { etaOverrides[r.sku] ?? r.etaDefault },
                                set: { etaOverrides[r.sku] = $0 }
                            ),
                            include: Binding(
                                get: { include[r.sku] ?? (r.suggested > 0) },
                                set: { include[r.sku] = $0 }
                            )
                        )
                    }
                }
                .frame(maxHeight: 420)
            }

            HStack(spacing: 12) {
                Button { generatePOs() } label: {
                    Label("Generar POs", systemImage: "shippingbox")
                }.buttonStyle(.borderedProminent)

                Button { exportCSV() } label: {
                    Label("Exportar CSV", systemImage: "square.and.arrow.up")
                }.buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Reabasto")
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("InventoryUpdated"))) { _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ForecastRatesUpdated"))) { notif in
            if let dict = notif.userInfo?["rates"] as? [String: Double] { forecastRates = dict; load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SupplyPlanUpdated"))) { _ in load() }
        .sheet(isPresented: $showShare) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func load() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "Item")
        req.sortDescriptors = [NSSortDescriptor(key: "sku", ascending: true)]
        do { items = try ctx.fetch(req) } catch { items = [] }
    }

    private var rows: [ReabastoData] {
        let now = Date()
        return items.compactMap { it in
            let sku = (it.value(forKey: "sku") as? String) ?? ""
            guard !sku.isEmpty else { return nil }
            let lt  = Int((it.value(forKey: "leadTimeDays") as? Int16) ?? 0)
            let rop = (it.value(forKey: "reorderPoint") as? Double) ?? 0
            let min = (it.value(forKey: "minStock") as? Double) ?? 0
            let unit = (it.value(forKey: "unit") as? String) ?? "pz"
            let stock = StockService.currentStock(for: sku, in: ctx)
            let weekly = forecastRates[sku] ?? ConsumptionService.averageWeeklyConsumption(for: sku, weeks: 4, asOf: now, in: ctx)

            let wos = weekly > 0 ? stock / weekly : 0
            let covDays = weekly > 0 ? (stock * 7.0 / weekly) : 0
            let stockLT = projectedStockAtLT(sku: sku, stock: stock, weekly: weekly, ltDays: lt, asOf: now)
            let need = (stockLT < rop) || (lt > 0 && covDays < Double(lt + 7))

            let target = weekly * max(1, targetWeeks)
            let suggestedRaw = max(0, target - stockLT)
            let suggested = suggestedRaw.rounded(.up)

            let etaDefault = Calendar.current.date(byAdding: .day, value: max(lt, 0), to: now) ?? now

            return ReabastoData(
                id: it.objectID, sku: sku, unit: unit, stock: stock, weekly: weekly,
                ltDays: lt, rop: rop, min: min, wos: wos, covDays: covDays,
                stockAtLT: stockLT, suggested: suggested, need: need, etaDefault: etaDefault
            )
        }
        .sorted { a, b in
            if a.need != b.need { return a.need && !b.need }
            return a.sku < b.sku
        }
    }

    private func projectedStockAtLT(sku: String, stock: Double, weekly: Double, ltDays: Int, asOf now: Date) -> Double {
        guard ltDays > 0 else { return stock }
        var s = stock
        let end = Calendar.current.date(byAdding: .day, value: ltDays, to: now) ?? now
        for po in POStore.shared.list(for: sku) where po.eta <= end { s += po.qty }
        for bo in BOStore.shared.list(for: sku) {
            if let due = bo.due {
                if due <= end { s -= bo.qty }
            } else {
                s -= bo.qty
            }
        }
        if weekly > 0 { s -= weekly * (Double(ltDays) / 7.0) }
        return s
    }

    private func generatePOs() {
        var newPOs: [PO] = []
        let now = Date()
        for r in rows {
            let inc = include[r.sku] ?? (r.suggested > 0)
            let qty = qtyOverrides[r.sku] ?? r.suggested
            if inc, qty > 0 {
                let eta = etaOverrides[r.sku] ?? r.etaDefault
                let poNum = "AUTO-\(Int(now.timeIntervalSince1970))"
                newPOs.append(PO(poNumber: poNum, sku: r.sku, qty: qty, eta: eta))
            }
        }
        guard !newPOs.isEmpty else { return }
        POStore.shared.replaceAll(POStore.shared.all() + newPOs) 
    }

    private func exportCSV() {
        let now = Date()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = .init(identifier: "en_US_POSIX")
        var lines: [String] = ["poNumber,sku,qty,eta"]
        for r in rows {
            let inc = include[r.sku] ?? (r.suggested > 0)
            let qty = qtyOverrides[r.sku] ?? r.suggested
            if inc, qty > 0 {
                let eta = etaOverrides[r.sku] ?? r.etaDefault
                let poNum = "AUTO-\(Int(now.timeIntervalSince1970))"
                lines.append("\(poNum),\(r.sku),\(Int(qty)),\(df.string(from: eta))")
            }
        }
        let text = lines.joined(separator: "\n")
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("reabasto-\(Int(now.timeIntervalSince1970)).csv")
            try text.data(using: .utf8)?.write(to: url)
            exportURL = url
            showShare = true
        } catch {
            print("Export CSV error: \(error)")
        }
    }

    struct ShareSheet: UIViewControllerRepresentable {
        let activityItems: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }
        func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
    }
}

private struct ReabastoData: Identifiable {
    let id: NSManagedObjectID
    let sku: String
    let unit: String
    let stock: Double
    let weekly: Double
    let ltDays: Int
    let rop: Double
    let min: Double
    let wos: Double
    let covDays: Double
    let stockAtLT: Double
    let suggested: Double
    let need: Bool
    let etaDefault: Date
}

private struct ReabastoRow: View {
    let row: ReabastoData
    @Binding var qty: Double
    @Binding var eta: Date
    @Binding var include: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.sku).font(.subheadline.weight(.semibold))
                Spacer()
                if row.need {
                    Text("Necesario")
                        .font(.caption2)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.thinMaterial, in: Capsule())
                }
            }
            HStack(spacing: 12) {
                Group {
                    kv("Stock", fmt(row.stock))
                    kv("Cons/sem", fmt(row.weekly))
                    kv("LT", "\(row.ltDays)d")
                    kv("WoS", fmt(row.wos))
                }
            }
            HStack(spacing: 12) {
                Group {
                    kv("Stock@LT", fmt(row.stockAtLT))
                    kv("ROP", fmt(row.rop))
                    kv("Min", fmt(row.min))
                    kv("Cob (d)", fmt(row.covDays))
                }
            }
            HStack(spacing: 12) {
                Toggle("Incluir", isOn: $include).labelsHidden()
                Stepper(value: $qty, in: 0...1_000_000, step: 1) {
                    Text("Sugerido: \(Int(qty)) \(row.unit)")
                        .font(.subheadline.monospacedDigit())
                }
                DatePicker("ETA", selection: $eta, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(UIColor.separator).opacity(0.25), lineWidth: 0.5)
        )
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundColor(.secondary)
            Text(v).font(.footnote.monospacedDigit())
        }
    }
    private func fmt(_ x: Double) -> String { x.isFinite ? (x < 10 ? String(format: "%.2f", x) : String(format: "%.0f", x)) : "—" }
}
