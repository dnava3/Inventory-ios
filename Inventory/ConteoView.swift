import SwiftUI
import CoreData

struct ConteoView: View {
    @Environment(\.managedObjectContext) private var ctx

    @State private var items: [NSManagedObject] = []
    @State private var search: String = ""

    @State private var draft: [CountEntry] = []

    enum Mode: String, CaseIterable, Identifiable { case fijar = "Fijar a conteo", delta = "Ajuste por delta"; var id: String { rawValue } }
    @State private var mode: Mode = .fijar
    @State private var area: String = ""
    @State private var shift: String = ""
    @State private var note: String = "Conteo cíclico"

    @State private var errorText: String?
    @State private var successText: String?

    var body: some View {
        List {
            if let ok = successText { Section { Text(ok).foregroundStyle(.green).font(.caption) } }
            if let err = errorText { Section { Text(err).foregroundStyle(.red).font(.caption) } }

            Section(header: Text("Configuración")) {
                Picker("Modo", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Área (opcional)", text: $area)
                TextField("Turno (opcional)", text: $shift)
                TextField("Nota", text: $note)
            }

            Section(header: Text("Agregar SKU")) {
                TextField("Buscar SKU o nombre", text: $search)
                let filtered = items.filter { it in
                    guard !search.isEmpty else { return false }
                    let sku = (it.value(forKey: "sku") as? String)?.lowercased() ?? ""
                    let name = (it.value(forKey: "name") as? String)?.lowercased() ?? ""
                    let q = search.lowercased()
                    return sku.contains(q) || name.contains(q)
                }
                if !filtered.isEmpty {
                    ForEach(filtered, id: \.objectID) { it in
                        let sku = (it.value(forKey: "sku") as? String) ?? ""
                        let name = (it.value(forKey: "name") as? String) ?? ""
                        let current = StockService.currentStock(for: sku, in: ctx)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(sku) • \(name)")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text("Stock actual: \(fmt(current))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                if !draft.contains(where: { $0.sku == sku }) {
                                    draft.append(.init(objectID: it.objectID, sku: sku, name: name, current: current, inputText: ""))
                                }
                                search = ""
                            } label: {
                                Image(systemName: draft.contains(where: { $0.sku == sku }) ? "checkmark" : "plus")
                            }
                        }
                    }
                } else if !search.isEmpty {
                    Text("Sin coincidencias").foregroundStyle(.secondary)
                } else {
                    Text("Escribe para buscar").foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Borrador de conteo"), footer: draftFooter) {
                if draft.isEmpty {
                    Text("Aún no agregas SKUs").foregroundStyle(.secondary)
                } else {
                    ForEach($draft) { $line in
                        CountRowView(line: $line, mode: mode)
                    }
                    .onDelete(perform: deleteDraft)
                }
            }

            if !draft.isEmpty {
                Section(header: Text("Resumen")) {
                    let totalMovs = draft.filter { abs($0.delta(for: mode)) > 0.0001 }.count
                    let deltaSum  = draft.map { $0.delta(for: mode) }.reduce(0, +)
                    Text("Ajustes a crear: \(totalMovs)").font(.subheadline)
                    Text("Suma neta de ajuste: \(fmt(deltaSum))").font(.caption).foregroundStyle(.secondary)
                    Button { commit() } label: {
                        Label("Guardar ajustes", systemImage: "tray.and.arrow.down.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Conteo")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !draft.isEmpty { Button("Limpiar") { draft.removeAll() } }
            }
        }
        .onAppear(perform: loadItems)
    }

    private func loadItems() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "Item")
        req.sortDescriptors = [NSSortDescriptor(key: "sku", ascending: true)]
        do { items = try ctx.fetch(req) }
        catch { errorText = "No se pudo cargar catálogo: \(error.localizedDescription)" }
    }

    private func deleteDraft(at offsets: IndexSet) { draft.remove(atOffsets: offsets) }

    private func commit() {
        errorText = nil; successText = nil
        var created = 0
        let now = Date()
        for line in draft {
            let delta = line.delta(for: mode)
            if abs(delta) < 0.0001 { continue }
            let mv = NSEntityDescription.insertNewObject(forEntityName: "Movement", into: ctx)
            mv.setValue(UUID(), forKey: "id")
            mv.setValue(Int16(2), forKey: "type") 
            mv.setValue(line.sku, forKey: "sku")
            mv.setValue(delta, forKey: "qty")
            mv.setValue(area.isEmpty ? nil : area, forKey: "area")
            mv.setValue(shift.isEmpty ? nil : shift, forKey: "shift")
            mv.setValue(note, forKey: "note")
            mv.setValue(now, forKey: "date")
            created += 1
        }
        do {
            if created == 0 { errorText = "No hay cambios para guardar."; return }
            try ctx.save()
            successText = "Se guardaron \(created) ajustes."
            draft.removeAll()
        } catch {
            errorText = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    private var draftFooter: some View {
        let total = draft.count
        let lines = draft.map { "\($0.sku)" }.joined(separator: ", ")
        return Text(total > 0 ? "SKUs en borrador: \(total) [\(lines)]" : "Agrega SKUs al borrador")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func fmt(_ v: Double) -> String { if v == floor(v) { return "\(Int(v))" } else { return String(format: "%.2f", v) } }
}

struct CountEntry: Identifiable, Equatable {
    let id = UUID()
    let objectID: NSManagedObjectID
    let sku: String
    let name: String
    let current: Double
    var inputText: String

    func parsed() -> Double { Double(inputText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0 }

    func delta(for mode: ConteoView.Mode) -> Double {
        switch mode {
        case .fijar:
            let counted = parsed()
            return counted - current
        case .delta:
            return parsed()
        }
    }
}

struct CountRowView: View {
    @Binding var line: CountEntry
    var mode: ConteoView.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(line.sku) • \(line.name)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer()
                Text("Stock: \(fmt(line.current))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if mode == .fijar {
                    TextField("Conteo", text: $line.inputText)
                        .keyboardType(.decimalPad)
                } else {
                    TextField("Δ Ajuste (+/-)", text: $line.inputText)
                        .keyboardType(.decimalPad)
                }
                Spacer(minLength: 8)
                let d = line.delta(for: mode)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Delta: \(fmt(d))").font(.caption)
                    let post = line.current + d
                    Text("Quedará: \(fmt(post))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func fmt(_ v: Double) -> String { if v == floor(v) { return "\(Int(v))" } else { return String(format: "%.2f", v) } }
}
