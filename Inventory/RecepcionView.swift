import SwiftUI
import CoreData

struct RecepcionView: View {
    @Environment(\.managedObjectContext) private var ctx

    @State private var selectedItem: NSManagedObject?
    @State private var skuText: String = ""
    @State private var qtyText: String = ""
    @State private var invoiceText: String = ""
    @State private var supplierText: String = ""
    @State private var costText: String = ""
    @State private var locationText: String = ""
    @State private var noteText: String = ""

    @FocusState private var qtyFocused: Bool

    @State private var showItemPicker = false
    @State private var showScanner = false
    @State private var alertMsg: String?
    @State private var onHandPreview: String = "—"

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
        req.predicate = NSPredicate(format: "type == %d", 0)
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
                        .onChange(of: skuText) { _, _ in
                            syncSelectedItemFromText()
                            refreshOnHandPreview()
                        }

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
                        Text("Stock estimado:")
                        Spacer()
                        Text(onHandPreview).font(.headline)
                    }
                }
            }

            Section(header: Text("Detalle de entrada")) {
                HStack {
                    TextField("Cantidad", text: $qtyText)
                        .keyboardType(.decimalPad)
                        .focused($qtyFocused)
                    Button("−") { stepQty(-1) }.buttonStyle(.bordered)
                    Button("+") { stepQty(1) }.buttonStyle(.bordered)
                }

                TextField("Factura / PO", text: $invoiceText)
                TextField("Proveedor", text: $supplierText)
                TextField("Costo (texto)", text: $costText)
                    .keyboardType(.decimalPad)
                TextField("Ubicación (tarima/mesa/isla)", text: $locationText)
                TextField("Notas", text: $noteText)
            }

            Section {
                Button(action: saveEntry) {
                    Label("Guardar entrada", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }

            if !recent.isEmpty {
                Section(header: Text("Últimas entradas")) {
                    ForEach(recent, id: \.objectID) { mv in
                        MovementRowEntrada(mv: mv)
                            .swipeActions {
                                Button(role: .destructive) {
                                    deleteMovement(mv)
                                } label: {
                                    Label("Borrar", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Recepción / Entradas")
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
        .onAppear {
            if skuText.isEmpty { syncSelectedItemFromText() }
            refreshOnHandPreview()
        }
    }


    private var canSave: Bool {
        guard selectedItem != nil else { return false }
        guard let q = Double(qtyText.replacingOccurrences(of: ",", with: ".")), q > 0 else { return false }
        return true
    }

    private func stepQty(_ delta: Double) {
        let current = Double(qtyText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let next = max(0, current + delta)
        qtyText = next == floor(next) ? String(Int(next)) : String(next)
    }

    private func syncSelectedItemFromText() {
        guard !skuText.isEmpty else { selectedItem = nil; return }
        if let exact = items.first(where: { ($0.value(forKey: "sku") as? String)?.uppercased() == skuText.uppercased() }) {
            selectedItem = exact
            return
        }
        if let first = items.first(where: { ($0.value(forKey: "sku") as? String)?.uppercased().hasPrefix(skuText.uppercased()) == true }) {
            selectedItem = first
        }
    }

    private func handleScanned(code: String) {
        skuText = code
        syncSelectedItemFromText()
        if selectedItem == nil {
            alertMsg = "Código \(code) no encontrado en el catálogo."
        } else {
            qtyFocused = true
            refreshOnHandPreview()
        }
    }

    private func refreshOnHandPreview() {
        guard let sku = (selectedItem?.value(forKey: "sku") as? String) ?? (skuText.isEmpty ? nil : skuText) else {
            onHandPreview = "—"; return
        }
        let v = StockService.currentStock(for: sku, in: ctx)
        onHandPreview = formatQty(v)
    }

    private func saveEntry() {
        guard canSave, let it = selectedItem else {
            alertMsg = "Completa SKU y cantidad."
            return
        }
        let sku = (it.value(forKey: "sku") as? String) ?? ""
        let qty = Double(qtyText.replacingOccurrences(of: ",", with: ".")) ?? 0

        let mv = NSEntityDescription.insertNewObject(forEntityName: "Movement", into: ctx)
        mv.setValue(UUID(), forKey: "id")
        mv.setValue(Int16(0), forKey: "type")
        mv.setValue(sku, forKey: "sku")
        mv.setValue(qty, forKey: "qty")
        mv.setValue(locationText.isEmpty ? nil : locationText, forKey: "area")
        mv.setValue(nil, forKey: "shift")
        let composedNote = composeNote()
        mv.setValue(composedNote.isEmpty ? (noteText.isEmpty ? nil : noteText) : composedNote + (noteText.isEmpty ? "" : " | \(noteText)"),
                    forKey: "note")
        mv.setValue(invoiceText.isEmpty ? nil : invoiceText, forKey: "ref")
        mv.setValue(Date(), forKey: "date")

        do {
            try ctx.save()
            qtyText = ""
            invoiceText = ""
            supplierText = ""
            costText = ""
            noteText = ""
            refreshOnHandPreview()
            qtyFocused = true
        } catch {
            alertMsg = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    private func composeNote() -> String {
        let s = supplierText.trimmingCharacters(in: .whitespaces)
        let c = costText.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if !s.isEmpty { parts.append("Proveedor=\(s)") }
        if !c.isEmpty { parts.append("Costo=\(c)") }
        return parts.joined(separator: "; ")
    }

    private func deleteMovement(_ mv: NSManagedObject) {
        ctx.delete(mv)
        do { try ctx.save(); refreshOnHandPreview() }
        catch { alertMsg = "No se pudo borrar: \(error.localizedDescription)" }
    }

    private func formatQty(_ v: Double) -> String {
        if v == floor(v) { return "\(Int(v))" }
        return String(format: "%.2f", v)
    }
}

private struct MovementRowEntrada: View {
    let mv: NSManagedObject
    var body: some View {
        let sku = (mv.value(forKey: "sku") as? String) ?? "—"
        let qty = (mv.value(forKey: "qty") as? Double) ?? 0
        let ref = (mv.value(forKey: "ref") as? String) ?? ""
        let area = (mv.value(forKey: "area") as? String) ?? ""
        let note = (mv.value(forKey: "note") as? String) ?? ""
        let date = (mv.value(forKey: "date") as? Date) ?? Date()

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(sku)  •  +\(formatQty(qty))").font(.body.weight(.semibold))
                Spacer()
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !ref.isEmpty {
                Text("Factura/PO: \(ref)").font(.footnote)
            }
            if !area.isEmpty {
                Text("Ubicación: \(area)").font(.footnote)
            }
            if !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func formatQty(_ v: Double) -> String {
        if v == floor(v) { return "\(Int(v))" }
        return String(v)
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
