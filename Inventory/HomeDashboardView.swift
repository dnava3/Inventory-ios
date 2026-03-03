import SwiftUI
import CoreData

struct HomeDashboardView: View {
    @Environment(\.managedObjectContext) private var ctx

    @State private var query: String = ""
    @State private var showScan = false
    @State private var showReabasto = false
    @State private var showConteo = false

    @State private var totalSKUs: Int = 0
    @State private var lowCount: Int = 0
    @State private var medianWoS: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    SurfaceCard {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Buscar SKU…", text: $query)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    HStack(spacing: 12) {
                        StatTile(title: "SKUs activos", value: "\(totalSKUs)")
                        StatTile(title: "Bajo stock", value: "\(lowCount)")
                        StatTile(title: "Mediana WoS", value: fmtWoS(medianWoS), subtitle: "semanas")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Acciones").font(.subheadline.weight(.semibold))
                        HStack(spacing: 12) {
                            TileButton("Escanear", systemImage: "barcode.viewfinder") { showScan = true }
                            TileButton("Reabasto", systemImage: "shippingbox") { showReabasto = true }
                            TileButton("Conteo", systemImage: "list.bullet.rectangle") { showConteo = true }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Críticos por cobertura").font(.subheadline.weight(.semibold))
                        SurfaceCard {
                            CriticalList(query: query)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Inventario")
            .onAppear(perform: refreshMetrics)
            .sheet(isPresented: $showScan) {
                BarcodeScannerView { _ in }
            }
            .sheet(isPresented: $showReabasto) {
                NavigationStack { ReabastoView() }
            }
            .sheet(isPresented: $showConteo) {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.largeTitle)
                    Text("Conteo cíclico").font(.title3.weight(.semibold))
                    Text("Próximo módulo. ¿Quieres que lo deje hoy con sesión de conteo y CSV de auditoría?")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Cerrar") { showConteo = false }
                }.padding()
            }
        }
    }

    private func refreshMetrics() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "Item")
        do {
            let items = try ctx.fetch(req)
            totalSKUs = items.count

            var wosValues: [Double] = []
            var low = 0
            let now = Date()
            for it in items {
                let sku = (it.value(forKey: "sku") as? String) ?? ""
                guard !sku.isEmpty else { continue }
                let stock = StockService.currentStock(for: sku, in: ctx)
                let weekly = ConsumptionService.averageWeeklyConsumption(for: sku, weeks: 4, asOf: now, in: ctx)
                let wos = weekly > 0 ? stock / weekly : 0
                wosValues.append(wos)
                if wos > 0, wos < 2 { low += 1 }
            }
            lowCount = low
            medianWoS = median(wosValues)
        } catch {
            totalSKUs = 0; lowCount = 0; medianWoS = 0
        }
    }

    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        if s.count % 2 == 0 { return (s[m-1] + s[m]) / 2 } else { return s[m] }
    }
    private func fmtWoS(_ v: Double) -> String { v < 10 ? String(format: "%.2f", v) : String(format: "%.0f", v) }
}

private struct CriticalList: View {
    @Environment(\.managedObjectContext) private var ctx
    let query: String

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows.prefix(10)) { r in
                HStack(alignment: .top, spacing: 10) {
                    StatusDot(r.status)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.sku).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                        Text("Stock: \(fmt(r.stock)) • Cons/sem: \(fmt(r.weekly)) • WoS: \(fmtWoS(r.wos))")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: min(max(r.wos/4.0, 0), 1)) 
                    }
                    Spacer()
                    Text(fmt(r.stock)).font(.headline.monospacedDigit())
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground)).opacity(0.35)
                )
            }
            if rows.isEmpty {
                Text("Sin SKUs críticos").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct Row: Identifiable { let id = UUID(); let sku: String; let stock: Double; let weekly: Double; let wos: Double; let status: StatusDot.Kind }

    private var rows: [Row] {
        let req = NSFetchRequest<NSManagedObject>(entityName: "Item")
        do {
            let items = try ctx.fetch(req)
            let lower = query.lowercased()
            let now = Date()
            let mapped: [Row] = items.compactMap { it in
                let sku = (it.value(forKey: "sku") as? String) ?? ""
                guard !sku.isEmpty else { return nil }
                if !lower.isEmpty && !sku.lowercased().contains(lower) { return nil }
                let stock = StockService.currentStock(for: sku, in: ctx)
                let weekly = ConsumptionService.averageWeeklyConsumption(for: sku, weeks: 4, asOf: now, in: ctx)
                let wos = weekly > 0 ? stock / weekly : 0
                let status: StatusDot.Kind = wos < 1 ? .bad : (wos < 2 ? .warn : .good)
                return Row(sku: sku, stock: stock, weekly: weekly, wos: wos, status: status)
            }
            return mapped.sorted { $0.wos < $1.wos } 
        } catch { return [] }
    }

    private func fmt(_ v: Double) -> String { v < 10 ? String(format: "%.2f", v) : String(format: "%.0f", v) }
    private func fmtWoS(_ v: Double) -> String { v < 10 ? String(format: "%.2f", v) : String(format: "%.0f", v) }
}
