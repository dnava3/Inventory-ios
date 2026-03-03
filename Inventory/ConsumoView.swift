import SwiftUI
import CoreData

struct ConsumoView: View {
    @Environment(\.managedObjectContext) private var ctx

    @State private var selectedItem: NSManagedObject?
    @State private var skuText: String = ""
    @State private var qtyText: String = ""
    @State private var area: String = ""
    @State private var shift: String = ""
    @State private var note: String = ""
    @State private var refText: String = ""
    @FocusState private var qtyFocused: Bool

    @State private var showItemPicker = false
    @State private var showScanner = false
    @State private var alertMsg: String?

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "sku", ascending: true)],
        animation: .default)
    private var items: FetchedResults<NSManagedObject>

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
        req.predicate = NSPredicate(format: "type == %d", 1)
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
                        }

                    Button {
                        showItemPicker = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Elegir SKU")

                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel("Escanear código")
                }

                if let it = selectedItem {
                    ItemMiniCard(item: it)
                }
            }

            Section(header: Text("Detalle")) {
                HStack {
                    TextField("Cantidad", text: $qtyText)
                        .keyboardType(.decimalPad)
                        .focused($qtyFocused)
                    Button("−") { stepQty(-1) }
                        .buttonStyle(.bordered)
                    Button("+") { stepQty(1) }
                        .buttonStyle(.bordered)
                }

                PickerTextField(title: "Área", text: $area, presets: ["Picking","Empaque","Devoluciones","Recepción","Reposición"])
                PickerTextField(title: "Turno", text: $shift, presets: ["A","B","C","Mixto"])

                TextField("Referencia (OP/orden)", text: $refText)
                TextField("Nota", text: $note)
            }

            Section {
                Button(action: saveConsumption) {
                    Label("Guardar consumo", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }

            if !recent.isEmpty {
                Section(header: Text("Últimos consumos")) {
                    ForEach(recent, id: \.objectID) { mv in
                        MovementRow(mv: mv)
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
        .navigationTitle("Consumo")
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
        } message: {
            Text(alertMsg ?? "")
        }
        .onAppear { if skuText.isEmpty {
            syncSelectedItemFromText()
        }}
    }

    private var canSave: Bool {
        guard let _ = selectedItem else { return false }
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
        }
    }

    private func saveConsumption() {
        guard canSave, let it = selectedItem else {
            alertMsg = "Completa SKU y cantidad."
            return
        }
        let sku = (it.value(forKey: "sku") as? String) ?? ""
        let qty = Double(qtyText.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard qty > 0 else {
            alertMsg = "La cantidad debe ser mayor a 0."
            return
        }

        let mv = NSEntityDescription.insertNewObject(forEntityName: "Movement", into: ctx)
        mv.setValue(UUID(), forKey: "id")
        mv.setValue(Int16(1), forKey: "type") 
        mv.setValue(sku, forKey: "sku")
        mv.setValue(qty, forKey: "qty")
        mv.setValue(area.isEmpty ? nil : area, forKey: "area")
        mv.setValue(shift.isEmpty ? nil : shift, forKey: "shift")
        mv.setValue(note.isEmpty ? nil : note, forKey: "note")
        mv.setValue(refText.isEmpty ? nil : refText, forKey: "ref")
        mv.setValue(Date(), forKey: "date")

        do {
            try ctx.save()
            qtyText = ""
            note = ""
            refText = ""
            qtyFocused = true
        } catch {
            alertMsg = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    private func deleteMovement(_ mv: NSManagedObject) {
        ctx.delete(mv)
        do { try ctx.save() }
        catch { alertMsg = "No se pudo borrar: \(error.localizedDescription)" }
    }
}

struct ItemMiniCard: View {
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

private struct MovementRow: View {
    let mv: NSManagedObject
    var body: some View {
        let sku = (mv.value(forKey: "sku") as? String) ?? "—"
        let qty = (mv.value(forKey: "qty") as? Double) ?? 0
        let area = (mv.value(forKey: "area") as? String) ?? ""
        let shift = (mv.value(forKey: "shift") as? String) ?? ""
        let date = (mv.value(forKey: "date") as? Date) ?? Date()

        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sku)  •  \(formatQty(qty))")
                    .font(.body.weight(.semibold))
                Text([area, shift].filter{ !$0.isEmpty }.joined(separator: " • "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func formatQty(_ v: Double) -> String {
        if v == floor(v) { return "\(Int(v))" }
        return String(v)
    }
}

private struct PickerTextField: View {
    let title: String
    @Binding var text: String
    let presets: [String]
    var body: some View {
        HStack {
            TextField(title, text: $text)
            Menu {
                ForEach(presets, id: \.self) { p in
                    Button(p) { text = p }
                }
                if !text.isEmpty {
                    Divider()
                    Button("Limpiar") { text = "" }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
        }
    }
}
