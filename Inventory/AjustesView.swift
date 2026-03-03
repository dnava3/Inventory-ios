import SwiftUI
import CoreData

struct AjustesView: View {
    @Environment(\.managedObjectContext) private var ctx


    @State private var selectedItem: NSManagedObject?
    @State private var skuText: String = ""
    @State private var showItemPicker = false
    @State private var showScanner = false


    @State private var opIndex: Int = 2
    private let ops = ["Agregar", "Descontar", "Fijar a"]

  
    @State private var reason: String = "Inventario inicial"
    private let reasons = ["Inventario inicial", "Merma", "Corrección", "Daño", "Otro"]

  
    @State private var qtyText: String = ""
    @State private var targetText: String = ""
    @State private var locationText: String = ""
    @State private var noteText: String = ""
    @State private var onHandPreview: String = "—"
    @State private var alertMsg: String?

   
    @FetchRequest private var items: FetchedResults<NSManagedObject>
 
    @FetchRequest private var recent: FetchedResults<NSManagedObject>

    init() {
       
        _items = FetchRequest(
            entity: NSEntityDescription.entity(forEntityName: "Item", in: PersistenceController.shared.container.viewContext)!,
            sortDescriptors: [NSSortDescriptor(key: "sku", ascending: true)],
            predicate: nil,
            animation: .default
        )
        let req = NSFetchRequest<NSManagedObject>(entityName: "Movement")
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        req.predicate = NSPredicate(format: "type == %d", 2)
        req.fetchLimit = 50
        _recent = FetchRequest(fetchRequest: req, animation: .default)
    }

    var body: some View {
        Form {
            Section(header: Text("SKU")) {
                HStack {
                    TextField("Buscar o escribir SKU", text: $skuText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .onChange(of: skuText) { syncSelectedItemFromText(); refreshOnHand() }

                    Button { showItemPicker = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Elegir SKU")

                    Button { showScanner = true } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel("Escanear código")
                }

                if let it = selectedItem {
                    ItemMiniCardInline(item: it)
                    HStack {
                        Text("Stock actual:")
                        Spacer()
                        Text(onHandPreview).font(.headline)
                    }
                }
            }

            Section(header: Text("Tipo de ajuste")) {
                Picker("Operación", selection: $opIndex) {
                    ForEach(ops.indices, id: \.self) { i in Text(ops[i]).tag(i) }
                }
                .pickerStyle(.segmented)

                Picker("Motivo", selection: $reason) {
                    ForEach(reasons, id: \.self) { Text($0) }
                }

                if opIndex == 2 {
                    TextField("Fijar existencias a…", text: $targetText)
                        .keyboardType(.decimalPad)
                    if let delta = computedDelta() {
                        let sign = delta >= 0 ? "+" : "−"
                        HStack {
                            Text("Resultado del ajuste:")
                            Spacer()
                            Text("\(sign)\(formatQty(abs(delta)))").font(.headline)
                        }
                    }
                } else {
                    HStack {
                        TextField(opIndex == 0 ? "Cantidad a agregar" : "Cantidad a descontar", text: $qtyText)
                            .keyboardType(.decimalPad)
                        Button("−1") { stepQty(-1) }.buttonStyle(.bordered)
                        Button("+1") { stepQty(1)  }.buttonStyle(.bordered)
                    }
                }

                TextField("Ubicación (tarima/mesa/isla)", text: $locationText)
                TextField("Notas", text: $noteText)
            }

            Section {
                Button(action: saveAdjustment) {
                    Label("Guardar ajuste", systemImage: "wrench.and.screwdriver.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }

            if !recent.isEmpty {
                Section(header: Text("Últimos ajustes")) {
                    ForEach(recent, id: \.objectID) { mv in
                        MovementRowAjuste(mv: mv)
                            .swipeActions {
                                Button(role: .destructive) { deleteMovement(mv) } label: {
                                    Label("Borrar", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Ajustes")
        .sheet(isPresented: $showItemPicker) {
            ItemPickerSheet(items: items.map{$0}, selected: $selectedItem, skuText: $skuText)
        }
        .sheet(isPresented: $showScanner) {
            BarcodeScannerView { code in
                showScanner = false
                handleScanned(code: code)
            }
        }
        .alert("Atención", isPresented: Binding(get: { alertMsg != nil }, set: { if !$0 { alertMsg = nil } })) {
            Button("OK", role: .cancel) { alertMsg = nil }
        } message: { Text(alertMsg ?? "") }
        .onAppear { if skuText.isEmpty { syncSelectedItemFromText() }; refreshOnHand() }
    }


    private var canSave: Bool {
        guard let _ = selectedItem else { return false }
        if opIndex == 2 {
            guard let delta = computedDelta() else { return false }
            return delta != 0
        } else {
            guard let q = Double(qtyText.replacingOccurrences(of: ",", with: ".")), q > 0 else { return false }
            return q > 0
        }
    }

    private func deleteMovement(_ mv: NSManagedObject) {
        ctx.delete(mv)
        do {
            try ctx.save()
            refreshOnHand()
        } catch {
            alertMsg = "No se pudo borrar: \(error.localizedDescription)"
        }
    }

    private func computedDelta() -> Double? {
        guard opIndex == 2 else { return nil }
        guard let it = selectedItem else { return nil }
        let sku = (it.value(forKey: "sku") as? String) ?? ""
        let current = StockService.currentStock(for: sku, in: ctx)
        guard let target = Double(targetText.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return target - current
    }

    private func stepQty(_ d: Double) {
        let current = Double(qtyText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let next = max(0, current + d)
        qtyText = next == floor(next) ? String(Int(next)) : String(next)
    }

    private func syncSelectedItemFromText() {
        guard !skuText.isEmpty else { selectedItem = nil; return }
        if let exact = items.first(where: { ($0.value(forKey: "sku") as? String)?.uppercased() == skuText.uppercased() }) {
            selectedItem = exact; return
        }
        if let first = items.first(where: { ($0.value(forKey: "sku") as? String)?.uppercased().hasPrefix(skuText.uppercased()) == true }) {
            selectedItem = first
        }
    }

    private func handleScanned(code: String) {
        skuText = code
        syncSelectedItemFromText()
        if selectedItem == nil { alertMsg = "Código \(code) no encontrado en el catálogo." }
        refreshOnHand()
    }

    private func refreshOnHand() {
        guard let sku = (selectedItem?.value(forKey: "sku") as? String) ?? (skuText.isEmpty ? nil : skuText) else {
            onHandPreview = "—"; return
        }
        onHandPreview = formatQty(StockService.currentStock(for: sku, in: ctx))
    }

    private func saveAdjustment() {
        guard let it = selectedItem else { alertMsg = "Selecciona un SKU."; return }

        let sku = (it.value(forKey: "sku") as? String) ?? ""
        var delta: Double = 0

        if opIndex == 2 {
            guard let d = computedDelta() else { alertMsg = "Objetivo inválido."; return }
            if d == 0 { alertMsg = "El stock ya coincide con el objetivo."; return }
            delta = d
        } else {
            guard let q = Double(qtyText.replacingOccurrences(of: ",", with: ".")), q > 0 else {
                alertMsg = "Cantidad inválida."; return
            }
            delta = (opIndex == 0) ? q : -q
        }

        let mv = NSEntityDescription.insertNewObject(forEntityName: "Movement", into: ctx)
        mv.setValue(UUID(), forKey: "id")
        mv.setValue(Int16(2), forKey: "type") 
        mv.setValue(sku, forKey: "sku")
        mv.setValue(delta, forKey: "qty")
        mv.setValue(locationText.isEmpty ? nil : locationText, forKey: "area")
        mv.setValue(nil, forKey: "shift")

        var parts: [String] = ["Ajuste=\(ops[opIndex])", "Motivo=\(reason)"]
        if !noteText.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(noteText) }
        mv.setValue(parts.joined(separator: " | "), forKey: "note")
        mv.setValue(Date(), forKey: "date")

        do {
            try ctx.save()
            if opIndex == 2 { targetText = "" } else { qtyText = "" }
            noteText = ""
            refreshOnHand()
        } catch { alertMsg = "No se pudo guardar: \(error.localizedDescription)" }
    }

    private func formatQty(_ v: Double) -> String {
        if v == floor(v) { return "\(Int(v))" }
        return String(format: "%.2f", v)
    }
}

private struct ItemMiniCardInline: View {
    let item: NSManagedObject
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text((item.value(forKey: "name") as? String) ?? "—")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Text("SKU: \((item.value(forKey: "sku") as? String) ?? "—")")
                    Text("UM: \((item.value(forKey: "unit") as? String) ?? "—")")
                }
                .foregroundStyle(.secondary)
                .font(.footnote)
            }
            Spacer()
        }
    }
}

private struct MovementRowAjuste: View {
    let mv: NSManagedObject
    var body: some View {
        let sku = (mv.value(forKey: "sku") as? String) ?? "—"
        let qty = (mv.value(forKey: "qty") as? Double) ?? 0
        let note = (mv.value(forKey: "note") as? String) ?? ""
        let date = (mv.value(forKey: "date") as? Date) ?? Date()
        let sign = qty >= 0 ? "+" : "−"
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(sku)  •  \(sign)\(formatQty(abs(qty)))").font(.body.weight(.semibold))
                Spacer()
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
    private func formatQty(_ v: Double) -> String {
        if v == floor(v) { return "\(Int(v))" }
        return String(v)
    }
}
