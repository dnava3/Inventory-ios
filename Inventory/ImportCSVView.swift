import SwiftUI
import CoreData
import UniformTypeIdentifiers
import UIKit

extension Notification.Name { static let inventoryUpdated = Notification.Name("InventoryUpdated") }
extension Notification.Name { static let forecastRatesUpdated = Notification.Name("ForecastRatesUpdated") }

struct ImportCSVView: View {
    @Environment(\.managedObjectContext) private var ctx

    @State private var showPicker = false
    @State private var summary: ImportSummary?
    @State private var errorText: String?

    var body: some View {
        List {
            Section(header: Text("Importar CSV")) {
                Button { showPicker = true } label: {
                    Label("Seleccionar CSV", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                if let err = errorText {
                    Text(err).font(.caption).foregroundColor(.red)
                }
            }

            if let s = summary {
                Section(header: Text("Resumen")) {
                    HStack { Text("SKUs creados"); Spacer(); Text("\(s.created)") }
                    HStack { Text("SKUs actualizados"); Spacer(); Text("\(s.updated)") }
                    HStack { Text("Ajustes de stock"); Spacer(); Text("\(s.adjusted)") }
                    if !s.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Observaciones").font(.subheadline)
                            ForEach(Array(s.warnings.prefix(10)), id: \.self) { w in
                                Text("• \(w)").font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Importar")
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in
                showPicker = false
                importCSV(at: url)
            }
        }
    }

    private func importCSV(at url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).csv")
            do { try FileManager.default.copyItem(at: url, to: tmp) } catch { /* si falla, usamos la URL original */ }
            let readURL = FileManager.default.fileExists(atPath: tmp.path) ? tmp : url

            let data = try Data(contentsOf: readURL)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                errorText = "No se pudo leer el archivo como texto (usa CSV UTF-8)."
                return
            }
            let result = CSVImporter(ctx: ctx).runImport(csvText: text)
            switch result {
            case .success(let s):
                summary = s
                errorText = nil
                let rates = extractForecastRates(from: text)
                NotificationCenter.default.post(name: .forecastRatesUpdated, object: nil, userInfo: ["rates": rates])
                NotificationCenter.default.post(name: .inventoryUpdated, object: nil)
            case .failure(let e):
                errorText = e.localizedDescription
            }
        } catch {
            errorText = "No se pudo abrir el archivo: \(error.localizedDescription)"
        }
    }

    private func extractForecastRates(from text: String) -> [String: Double] {
        func normalize(_ s: String) -> String {
            let k = s.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            switch k {
            case "sku": return "sku"
            case "weeklydemand", "demandasemanal", "consumosemanal", "consumopromsemanal", "proyeccionsemanal", "proyeccion", "forecast": return "weeklyDemand"
            default: return k
            }
        }
        func parseLine(_ line: String, sep: Character) -> [String] {
            var result: [String] = []
            var current = ""
            var inQuotes = false
            var i = line.startIndex
            while i < line.endIndex {
                let ch = line[i]
                if ch == "\"" {
                    if inQuotes {
                        let next = line.index(after: i)
                        if next < line.endIndex && line[next] == "\"" { current.append("\""); i = next }
                        else { inQuotes = false }
                    } else { inQuotes = true }
                } else if ch == sep && !inQuotes {
                    result.append(current); current = ""
                } else { current.append(ch) }
                i = line.index(after: i)
            }
            result.append(current)
            return result
        }
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [:] }
        let headerLine = lines[0]
        let seps: [Character] = [",", ";", "\t"]
        let counts = seps.map { sep in headerLine.filter { $0 == sep }.count }
        let sep = seps[counts.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0]
        let rawHeaders = parseLine(headerLine, sep: sep)
        let headers = rawHeaders.map(normalize)

        func isWeekCol(_ key: String) -> Bool {
            let k = key
            if k.hasPrefix("w") || k.hasPrefix("wk") || k.hasPrefix("week") || k.hasPrefix("sem") || k.hasPrefix("semana") {
                return k.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil
            }
            return false
        }

        var skuIdx: Int? = nil
        var weeklyIdx: Int? = nil
        var weekIdxs: [Int] = []
        for (i, h) in headers.enumerated() {
            if h == "sku" { skuIdx = i }
            else if h == "weeklyDemand" { weeklyIdx = i }
            else if isWeekCol(h) { weekIdxs.append(i) }
        }
        guard let sIdx = skuIdx else { return [:] }

        var out: [String: Double] = [:]
        for i in 1..<lines.count {
            let raw = lines[i]
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let vals = parseLine(raw, sep: sep)
            guard sIdx < vals.count else { continue }
            let sku = vals[sIdx].trimmingCharacters(in: .whitespaces)
            if sku.isEmpty { continue }

            var rate: Double? = nil
            if let w = weeklyIdx, w < vals.count {
                let s = vals[w].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                if let v = Double(s), v > 0 { rate = v }
            }
            if rate == nil, !weekIdxs.isEmpty {
                var arr: [Double] = []
                for wi in weekIdxs where wi < vals.count {
                    let s = vals[wi].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                    if let v = Double(s), v > 0 { arr.append(v) }
                }
                if !arr.isEmpty { rate = arr.reduce(0,+) / Double(arr.count) }
            }
            if let r = rate, r.isFinite, r > 0 { out[sku] = r }
        }
        return out
    }
}

fileprivate struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let csv = UTType(filenameExtension: "csv") ?? .plainText
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [csv, .plainText, .data])
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

private func normalizeKey(_ s: String) -> String {
    let k = s.lowercased()
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "(", with: "")
        .replacingOccurrences(of: ")", with: "")
    switch k {
    case "sku": return "sku"
    case "name", "nombre": return "name"
    case "unit", "um", "unidad": return "unit"
    case "minstock", "minimo", "min", "safetystock", "stockseguridad", "seguridad": return "minStock"
    case "reorderpoint", "rop", "puntodereorden", "puntoedereorden": return "reorderPoint"
    case "leadtimedays", "leadtime", "lt", "tiempodeentrega": return "leadTimeDays"
    case "stock", "onhand", "inventario": return "stock"
    case "barcode", "ean", "ean13", "codigo", "codigodebarras", "codbarras", "upc": return "barcode"
    default: return k
    }
}

struct ImportSummary {
    var created: Int
    var updated: Int
    var adjusted: Int
    var warnings: [String]
}

fileprivate struct CSVImporter {
    let ctx: NSManagedObjectContext

    func runImport(csvText: String) -> Result<ImportSummary, Error> {
        do {
            let rows = try parseCSV(csvText)
            return apply(rows: rows)
        } catch { return .failure(error) }
    }

    private func apply(rows: [[String:String]]) -> Result<ImportSummary, Error> {
        var created = 0, updated = 0, adjusted = 0
        var warnings: [String] = []
        let now = Date()

        do {
            for row in rows {
                guard let rawSKU = row["sku"], !rawSKU.trimmingCharacters(in: .whitespaces).isEmpty else {
                    warnings.append("Fila sin SKU, se omitió.")
                    continue
                }
                let sku = rawSKU.trimmingCharacters(in: .whitespaces)
                if let barcode = nonEmpty(row["barcode"]) {
                    BarcodeStore.shared.set(barcode: barcode, sku: sku)
                }

                let fetch = NSFetchRequest<NSManagedObject>(entityName: "Item")
                fetch.predicate = NSPredicate(format: "sku == %@", sku)
                fetch.fetchLimit = 1
                let existing = try ctx.fetch(fetch).first

                let item: NSManagedObject
                if let ex = existing {
                    item = ex
                    updated += 1
                } else {
                    item = NSEntityDescription.insertNewObject(forEntityName: "Item", into: ctx)
                    item.setValue(sku, forKey: "sku")
                    item.setValue(true, forKey: "active")
                    if (item.value(forKey: "name") as? String) == nil { item.setValue("—", forKey: "name") }
                    if (item.value(forKey: "unit") as? String) == nil { item.setValue("pz", forKey: "unit") }
                    created += 1
                }

                if let name = nonEmpty(row["name"]) { item.setValue(name, forKey: "name") }
                if let unit = nonEmpty(row["unit"]) { item.setValue(unit, forKey: "unit") }
                if let minStock = double(row["minStock"]) { item.setValue(minStock, forKey: "minStock") }
                if let reorderPoint = double(row["reorderPoint"]) { item.setValue(reorderPoint, forKey: "reorderPoint") }
                if let leadTime = int16(row["leadTimeDays"]) { item.setValue(leadTime, forKey: "leadTimeDays") }
                item.setValue(now, forKey: "updatedAt")

                if let target = double(row["stock"]) {
                    let current = StockService.currentStock(for: sku, in: ctx)
                    let delta = target - current
                    if abs(delta) > 0.0001 {
                        let mv = NSEntityDescription.insertNewObject(forEntityName: "Movement", into: ctx)
                        mv.setValue(UUID(), forKey: "id")
                        mv.setValue(Int16(2), forKey: "type") 
                        mv.setValue(sku, forKey: "sku")
                        mv.setValue(delta, forKey: "qty")
                        mv.setValue(nil, forKey: "area")
                        mv.setValue(nil, forKey: "shift")
                        mv.setValue("Import CSV", forKey: "note")
                        mv.setValue(now, forKey: "date")
                        adjusted += 1
                    }
                } else {
                    warnings.append("SKU \(sku): sin columna 'stock'; no se fijó inventario.")
                }
            }

            try ctx.save()
            return .success(.init(created: created, updated: updated, adjusted: adjusted, warnings: warnings))
        } catch {
            return .failure(error)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
    private func double(_ value: String?) -> Double? {
        guard let s = value?.replacingOccurrences(of: ",", with: ".") else { return nil }
        return Double(s.trimmingCharacters(in: .whitespaces))
    }
    private func int16(_ value: String?) -> Int16? {
        guard let s = value?.trimmingCharacters(in: .whitespaces), let i = Int16(s) else { return nil }
        return i
    }

    private enum CSVError: Error, LocalizedError { case empty
        var errorDescription: String? { "El CSV está vacío." }
    }

    private func parseCSV(_ text: String) throws -> [[String: String]] {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { throw CSVError.empty }

        let headerLine = lines[0]
        let seps: [Character] = [",", ";", "\t"]
        let counts = seps.map { sep in headerLine.filter { $0 == sep }.count }
        let bestIndex = counts.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let sep = seps[bestIndex]

        let headers = parseCSVLine(headerLine, separator: sep).map { normalizeKey($0) }
        var rows: [[String: String]] = []
        for i in 1..<lines.count {
            let raw = lines[i]
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let values = parseCSVLine(raw, separator: sep)
            var dict: [String: String] = [:]
            for (idx, key) in headers.enumerated() where idx < values.count {
                dict[key] = values[idx]
            }
            rows.append(dict)
        }
        return rows
    }

    private func parseCSVLine(_ line: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                if inQuotes {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" { current.append("\""); i = next }
                    else { inQuotes = false }
                } else { inQuotes = true }
            } else if ch == separator && !inQuotes {
                result.append(current); current = ""
            } else { current.append(ch) }
            i = line.index(after: i)
        }
        result.append(current)
        return result
    }
}
