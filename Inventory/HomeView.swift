import SwiftUI
import CoreData
import AVFoundation
import PhotosUI
import UIKit

final class BarcodeStore {
    static let shared = BarcodeStore()
    private let key = "BarcodeMap"
    private let ud = UserDefaults.standard
    private var cache: [String: String]
    private init() { cache = ud.dictionary(forKey: key) as? [String: String] ?? [:] }
    func sku(for barcode: String) -> String? { cache[barcode] }
    func set(barcode: String, sku: String) { cache[barcode] = sku; ud.set(cache, forKey: key) }
    func remove(barcode: String) { cache.removeValue(forKey: barcode); ud.set(cache, forKey: key) }
}

struct PO: Codable { let poNumber: String; let sku: String; let qty: Double; let eta: Date }
struct BO: Codable { let sku: String; let qty: Double; let due: Date? }

final class POStore {
    static let shared = POStore()
    private let key = "POStore.v1"
    private let ud = UserDefaults.standard
    private var cache: [PO] = []
    private init() {
        if let data = ud.data(forKey: key), let arr = try? JSONDecoder().decode([PO].self, from: data) { cache = arr }
    }
    func all() -> [PO] { cache }
    func list(for sku: String) -> [PO] { cache.filter { $0.sku == sku } }
    func replaceAll(_ arr: [PO]) {
        cache = arr
        if let data = try? JSONEncoder().encode(arr) { ud.set(data, forKey: key) }
        NotificationCenter.default.post(name: Notification.Name("SupplyPlanUpdated"), object: nil)
    }
    func count() -> Int { cache.count }
}

final class BOStore {
    static let shared = BOStore()
    private let key = "BOStore.v1"
    private let ud = UserDefaults.standard
    private var cache: [BO] = []
    private init() {
        if let data = ud.data(forKey: key), let arr = try? JSONDecoder().decode([BO].self, from: data) { cache = arr }
    }
    func all() -> [BO] { cache }
    func list(for sku: String) -> [BO] { cache.filter { $0.sku == sku } }
    func replaceAll(_ arr: [BO]) {
        cache = arr
        if let data = try? JSONEncoder().encode(arr) { ud.set(data, forKey: key) }
        NotificationCenter.default.post(name: Notification.Name("SupplyPlanUpdated"), object: nil)
    }
    func count() -> Int { cache.count }
}

struct HomeView: View {
    @Environment(\.managedObjectContext) private var ctx
    @State private var navPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard {
                        GlassHero()
                    }
                    
                    GlassCard {
                        DashboardStats()
                    }
                    
                    GlassCard {
                        QuickActionsRow { route in
                            navPath.append(route)
                        }
                    }
                    
                    GlassCard {
                        StockListView(onTapSKU: { navPath.append(Route.skuDetail($0)) })
                            .padding(.top, 4)
                    }
                }
                .padding()
            }
            .navigationTitle("Inicio")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                EmptyStateOverlay(onAction: { navPath.append($0) })
            }
            .onAppear {
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .skuDetail(let sku):
                    SKUDetailView(sku: sku)
                case .escanear:
                    ScanAndRegisterView()
                case .reabasto:
                    ReabastoView()
                case .importar:
                    ImportCSVView()
                case .ajustes:
                    AjustesView()
                case .recepcion:
                    RecepcionView()
                case .conteo:
                    ConteoView()
                case .consumo:
                    ConsumoView()
                case .nuevoSKU:
                    AddSKUView()
                }
            }
        }
    }
    
    private func clearSeededDataIfNeeded() {
        let flagKey = "DidClearSeededData.v2"
        let ud = UserDefaults.standard
        guard ud.bool(forKey: flagKey) == false else { return }

        let legacySKUs = ["K00", "K01", "LBL"]

        let check = NSFetchRequest<NSFetchRequestResult>(entityName: "Item")
        check.predicate = NSPredicate(format: "sku IN %@", legacySKUs)
        check.fetchLimit = 1
        let hasLegacy = ((try? ctx.count(for: check)) ?? 0) > 0

        guard hasLegacy else {
            ud.set(true, forKey: flagKey)
            return
        }

        ctx.performAndWait {
            do {
                let mvFetch = NSFetchRequest<NSFetchRequestResult>(entityName: "Movement")
                mvFetch.predicate = NSPredicate(format: "sku IN %@", legacySKUs)
                let mvDel = NSBatchDeleteRequest(fetchRequest: mvFetch)
                mvDel.resultType = .resultTypeObjectIDs
                if let result = try ctx.execute(mvDel) as? NSBatchDeleteResult,
                   let ids = result.result as? [NSManagedObjectID],
                   !ids.isEmpty {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [ctx])
                }
            } catch {
                print("Batch delete Movement legacy error: \(error)")
            }

            do {
                let itFetch = NSFetchRequest<NSFetchRequestResult>(entityName: "Item")
                itFetch.predicate = NSPredicate(format: "sku IN %@", legacySKUs)
                let itDel = NSBatchDeleteRequest(fetchRequest: itFetch)
                itDel.resultType = .resultTypeObjectIDs
                if let result = try ctx.execute(itDel) as? NSBatchDeleteResult,
                   let ids = result.result as? [NSManagedObjectID],
                   !ids.isEmpty {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [ctx])
                }
            } catch {
                print("Batch delete Item legacy error: \(error)")
            }

            do { try ctx.save() } catch { }
        }

        ud.set([String: String](), forKey: "BarcodeMap")
        POStore.shared.replaceAll([])
        BOStore.shared.replaceAll([])

        ud.set(true, forKey: flagKey)

        NotificationCenter.default.post(name: Notification.Name("InventoryUpdated"), object: nil)
        NotificationCenter.default.post(name: Notification.Name("SupplyPlanUpdated"), object: nil)
    }
    
    enum Route: Hashable {
        case consumo, reabasto, conteo, recepcion, ajustes, importar, escanear, nuevoSKU
        case skuDetail(String)
    }}

struct BigTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
struct QuickActionsRow: View {
    let didTap: (HomeView.Route) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                QAButton(title: "Escanear", systemImage: "barcode.viewfinder") { didTap(.escanear) }
                QAButton(title: "Agregar SKU", systemImage: "plus") { didTap(.nuevoSKU) }
                QAButton(title: "Consumo", systemImage: "scissors") { didTap(.consumo) }
                QAButton(title: "Recepción", systemImage: "tray.and.arrow.down") { didTap(.recepcion) }
                QAButton(title: "Conteo", systemImage: "checkmark.seal") { didTap(.conteo) }
                QAButton(title: "Reabasto", systemImage: "arrow.triangle.2.circlepath") { didTap(.reabasto) }
                QAButton(title: "Ajustes", systemImage: "wrench.and.screwdriver") { didTap(.ajustes) }
                QAButton(title: "Importar", systemImage: "square.and.arrow.down.on.square") { didTap(.importar) }
            }
            .padding(.vertical, 4)
        }
    }
}

struct QAButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .imageScale(.medium)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color(UIColor.separator).opacity(0.25), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
struct GlassCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(UIColor.separator).opacity(0.25), lineWidth: 0.5)
        )
        .shadow(radius: 0.5)
    }
}
struct GlassHero: View {
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Control de Insumos")
                    .font(.largeTitle.weight(.semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Date.now, style: .date)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text(Date.now, style: .time)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct DashboardStats: View {
    @Environment(\.managedObjectContext) private var ctx
    @State private var items: [NSManagedObject] = []
    @State private var forecastRates: [String: Double] = [:]
    private let redThreshold: Double = 1.5

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 120), spacing: 12)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resumen")
                .font(.title3.weight(.semibold))
            LazyVGrid(columns: columns, spacing: 12) {
                StatCard(title: "SKUs", value: "\(items.count)", systemImage: "number")
                StatCard(title: "Críticos", value: "\(criticalCount())", systemImage: "exclamationmark.triangle")
                StatCard(title: "Cobertura prom.", value: wosAvgText(), systemImage: "clock.arrow.circlepath")
                StatCard(title: "POs (14d)", value: "\(upcomingPOs())", systemImage: "shippingbox")
                StatCard(title: "BOs (14d)", value: "\(upcomingBOs())", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("InventoryUpdated"))) { _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ForecastRatesUpdated"))) { notif in
            if let dict = notif.userInfo?["rates"] as? [String: Double] { forecastRates = dict; load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SupplyPlanUpdated"))) { _ in load() }
    }

    private func load() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "Item")
        req.sortDescriptors = [NSSortDescriptor(key: "sku", ascending: true)]
        do { items = try ctx.fetch(req) } catch { items = [] }
    }

    private func wosAvgText() -> String {
        let arr = items.compactMap { it -> Double? in
            let sku = (it.value(forKey: "sku") as? String) ?? ""
            let weekly = forecastRates[sku] ?? ConsumptionService.averageWeeklyConsumption(for: sku, weeks: 4, asOf: Date(), in: ctx)
            guard weekly > 0 else { return nil }
            let stock = StockService.currentStock(for: sku, in: ctx)
            return stock / weekly
        }
        guard !arr.isEmpty else { return "—" }
        let avg = arr.reduce(0, +) / Double(arr.count)
        return avg < 10 ? String(format: "%.2f", avg) : String(format: "%.0f", avg)
    }

    private func criticalCount() -> Int {
        items.reduce(0) { acc, it in
            let sku  = (it.value(forKey: "sku") as? String) ?? ""
            let min  = (it.value(forKey: "minStock") as? Double) ?? 0
            let rop  = (it.value(forKey: "reorderPoint") as? Double) ?? 0
            let lt   = ((it.value(forKey: "leadTimeDays") as? Int16).map(Int.init)) ?? 0
            let stock = StockService.currentStock(for: sku, in: ctx)
            let weekly = forecastRates[sku] ?? ConsumptionService.averageWeeklyConsumption(for: sku, weeks: 4, asOf: Date(), in: ctx)
            let wos = weekly > 0 ? stock / weekly : Double.greatestFiniteMagnitude
            let covD = weekly > 0 ? (stock * 7.0 / weekly) : Double.greatestFiniteMagnitude
            let coversLT = (lt == 0) ? true : (covD >= Double(lt))
            let byWos = wos < redThreshold
            let byMin = stock < min
            let byROP = rop > 0 ? (stock < rop) : false
            let byLT = (lt > 0) ? (!coversLT) : false
            return acc + ((byWos || byMin || byROP || byLT) ? 1 : 0)
        }
    }

    private func upcomingPOs(days: Int = 14) -> Int {
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: now) else { return 0 }
        return POStore.shared.all().filter { $0.eta >= now && $0.eta <= end }.count
    }

    private func upcomingBOs(days: Int = 14) -> Int {
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: now) else { return 0 }
        return BOStore.shared.all().filter { bo in
            if let d = bo.due { return d >= now && d <= end }
            return true
        }.count
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(UIColor.separator).opacity(0.25), lineWidth: 0.5)
        )
    }
}

struct ScanAndRegisterView: View {
    @Environment(\.managedObjectContext) private var ctx

    @State private var lastCode: String? = nil
    @State private var quantity: Double = 1
    @State private var detectedSKU: String? = nil
    @State private var linkSKU: String = ""
    @State private var cameraDenied: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                BarcodeScannerView { code in
                    if lastCode != code {
                        lastCode = code
                        detectedSKU = BarcodeStore.shared.sku(for: code)
                    }
                }
                .ignoresSafeArea(edges: .top)

                VStack { Spacer() }
            }
            .frame(maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Código:").foregroundColor(.secondary)
                        Text(lastCode ?? "—").font(.body.monospaced())
                        Spacer()
                    }
                    if let code = lastCode {
                        HStack {
                            Text("SKU detectado:").foregroundColor(.secondary)
                            Text(detectedSKU ?? "—").font(.body.monospaced())
                            Spacer()
                        }
                        if detectedSKU == nil {
                            HStack(spacing: 8) {
                                TextField("SKU", text: $linkSKU)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    let sku = linkSKU.trimmingCharacters(in: .whitespaces)
                                    guard !sku.isEmpty else { return }
                                    BarcodeStore.shared.set(barcode: code, sku: sku)
                                    detectedSKU = sku
                                    linkSKU = ""
                                } label: { Label("Vincular", systemImage: "link") }
                            }
                        }
                    }
                    HStack {
                        Text("Cantidad:").foregroundColor(.secondary)
                        Stepper(value: $quantity, in: 1...999, step: 1) {
                            Text("\(Int(quantity))")
                        }
                        .frame(maxWidth: 160)
                        Spacer()
                    }
                    HStack(spacing: 12) {
                        Button(role: .none) { if let code = lastCode { registerScan(code: code, qty: quantity) } } label: {
                            Label("Registrar", systemImage: "tray.and.arrow.down.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(lastCode == nil)

                        Button { lastCode = nil } label: { Label("Escanear de nuevo", systemImage: "barcode.viewfinder") }
                        .buttonStyle(.bordered)
                    }
                }
            } label: { Label("Registro por escaneo", systemImage: "barcode") }

            Spacer()
        }
        .padding()
        .navigationTitle("Escanear")
        .alert("Sin acceso a la cámara", isPresented: $cameraDenied) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Concede permiso en Ajustes > Privacidad > Cámara para poder escanear códigos.")
        }
    }

    private func registerScan(code: String, qty: Double) {
        let now = Date()
        let sku = BarcodeStore.shared.sku(for: code) ?? code
        do {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Item")
            fetch.predicate = NSPredicate(format: "sku == %@", sku)
            fetch.fetchLimit = 1
            let existing = try ctx.fetch(fetch).first
            let item: NSManagedObject
            if let ex = existing { item = ex }
            else {
                item = NSEntityDescription.insertNewObject(forEntityName: "Item", into: ctx)
                item.setValue(sku, forKey: "sku")
                item.setValue(true, forKey: "active")
                if (item.value(forKey: "unit") as? String) == nil { item.setValue("pz", forKey: "unit") }
                item.setValue(now, forKey: "updatedAt")
            }

            let mv = NSEntityDescription.insertNewObject(forEntityName: "Movement", into: ctx)
            mv.setValue(UUID(), forKey: "id")
            mv.setValue(Int16(0), forKey: "type")
            mv.setValue(sku, forKey: "sku")
            mv.setValue(qty, forKey: "qty")
            mv.setValue(nil, forKey: "area")
            mv.setValue(nil, forKey: "shift")
            mv.setValue("Recepción (escáner)", forKey: "note")
            mv.setValue(now, forKey: "date")

            try ctx.save()
            NotificationCenter.default.post(name: .inventoryUpdated, object: nil)
        } catch {
            print("Scan register error: \(error)")
        }
    }
}

struct CameraScannerView: UIViewRepresentable {
    var onCodeFound: (String) -> Void
    var onPermissionDenied: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onCodeFound: onCodeFound, onPermissionDenied: onPermissionDenied) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = context.coordinator.session
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        context.coordinator.configureSession()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized {
            if !context.coordinator.session.isRunning, context.coordinator.isConfigured {
                context.coordinator.session.startRunning()
            }
        }
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        if coordinator.session.isRunning {
            coordinator.session.stopRunning()
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        private let onCodeFound: (String) -> Void
        private let onPermissionDenied: (() -> Void)?
        private(set) var isConfigured = false

        init(onCodeFound: @escaping (String) -> Void, onPermissionDenied: (() -> Void)?) {
            self.onCodeFound = onCodeFound
            self.onPermissionDenied = onPermissionDenied
        }

        func configureSession() {
            if Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") == nil {
                onPermissionDenied?()
                return
            }
#if targetEnvironment(simulator)
            onPermissionDenied?()
            return
#endif
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                if !isConfigured { setupSession() }
                if !session.isRunning { session.startRunning() }
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            if !self.isConfigured { self.setupSession() }
                            if !self.session.isRunning { self.session.startRunning() }
                        }
                        else { self.onPermissionDenied?() }
                    }
                }
            case .denied, .restricted:
                onPermissionDenied?()
            @unknown default:
                onPermissionDenied?()
            }
        }

        private func setupSession() {
            guard let device = AVCaptureDevice.default(for: .video) else {
                onPermissionDenied?()
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                session.commitConfiguration(); onPermissionDenied?(); return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { session.commitConfiguration(); onPermissionDenied?(); return }
            session.addOutput(output)

            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            let types: [AVMetadataObject.ObjectType] = [
                .ean8, .ean13, .upce, .code39, .code39Mod43, .code93, .code128,
                .interleaved2of5, .itf14, .qr
            ]
            output.metadataObjectTypes = output.availableMetadataObjectTypes.filter { types.contains($0) }
            session.commitConfiguration()
            isConfigured = true
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
                  let code = obj.stringValue, !code.isEmpty else { return }
            onCodeFound(code)
        }
    }
}
struct StockListView: View {
    let onTapSKU: ((String) -> Void)?

    init(onTapSKU: ((String) -> Void)? = nil) {
        self.onTapSKU = onTapSKU
    }
    @Environment(\.managedObjectContext) private var ctx

    @State private var items: [NSManagedObject] = []
    @State private var query: String = ""
    @State private var onlyCritical: Bool = false
    @State private var sort: Sort = .criticalFirst
    @State private var forecastRates: [String: Double] = [:]

    private let redThreshold:   Double = 1.5
    private let amberThreshold: Double = 3.0

    private struct Row: Identifiable {
        let id: NSManagedObjectID
        let sku: String
        let unit: String
        let minStock: Double
        let reorderPoint: Double
        let leadTimeDays: Int
        let stock: Double
        let avgWeekly: Double
        let wos: Double?
        let coverageDays: Double?
        let depleteDate: Date?
        let coversLT: Bool
        let isCritical: Bool
    }

    enum Sort: String, CaseIterable, Identifiable {
        case criticalFirst = "Críticos"
        case stockAsc = "Stock ↑"
        case stockDesc = "Stock ↓"
        case sku = "SKU"
        var id: String { rawValue }
    }

    private var rows: [Row] {
        let lower = query.lowercased()
        let mapped: [Row] = items
            .filter { it in
                guard !query.isEmpty else { return true }
                let s = (it.value(forKey: "sku") as? String)?.lowercased() ?? ""
                return s.contains(lower)
            }
            .map { it in
                let sku  = (it.value(forKey: "sku") as? String) ?? ""
                let unit = (it.value(forKey: "unit") as? String) ?? ""
                let min  = (it.value(forKey: "minStock") as? Double) ?? 0
                let rop  = (it.value(forKey: "reorderPoint") as? Double) ?? 0
                let lt   = ((it.value(forKey: "leadTimeDays") as? Int16).map(Int.init)) ?? 0

                let stock = StockService.currentStock(for: sku, in: ctx)
                let weekly = forecastRates[sku] ?? ConsumptionService.averageWeeklyConsumption(for: sku, weeks: 4, asOf: Date(), in: ctx)
                let sim = simulateCoverage(for: sku, stock: stock, weekly: weekly, asOf: Date())
                let avg   = weekly
                let wos   = sim.wos
                let covD  = sim.coverageDays
                let dep   = sim.depleteDate
                let coversLT = (lt == 0) ? true : ((covD ?? 0) >= Double(lt))

                let criticalByWos = (wos ?? Double.greatestFiniteMagnitude) < redThreshold
                let criticalByMin = stock < min
                let criticalByROP = rop > 0 ? (stock < rop) : false
                let criticalByLT  = (lt > 0) ? ((!coversLT)) : false
                let isCritical = criticalByWos || criticalByMin || criticalByROP || criticalByLT

                return Row(id: it.objectID, sku: sku, unit: unit,
                           minStock: min, reorderPoint: rop, leadTimeDays: lt,
                           stock: stock, avgWeekly: avg, wos: wos,
                           coverageDays: covD, depleteDate: dep, coversLT: coversLT,
                           isCritical: isCritical)
            }
            .filter { onlyCritical ? $0.isCritical : true }

        switch sort {
        case .criticalFirst:
            return mapped.sorted { a, b in
                if a.isCritical != b.isCritical { return a.isCritical && !b.isCritical }
                switch (a.wos, b.wos) {
                case let (l?, r?): return l == r ? (a.sku < b.sku) : (l < r)
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.sku < b.sku
                }
            }
        case .stockAsc:
            return mapped.sorted { a, b in
                if a.stock == b.stock { return a.sku < b.sku }
                return a.stock < b.stock
            }
        case .stockDesc:
            return mapped.sorted { a, b in
                if a.stock == b.stock { return a.sku < b.sku }
                return a.stock > b.stock
            }
        case .sku:
            return mapped.sorted { $0.sku < $1.sku }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Inventario")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { loadItems() } label: { Image(systemName: "arrow.clockwise") }
            }

            TextField("Buscar SKU", text: $query)
                .textFieldStyle(.roundedBorder)

            HStack {
                Toggle("Solo críticos", isOn: $onlyCritical)
                Spacer()
                Picker("Orden", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            let total = rows.count
            let crit  = rows.filter { $0.isCritical }.count
            let sum   = rows.map { $0.stock }.reduce(0, +)
            HStack(spacing: 16) {
                Label("\(total) SKUs", systemImage: "number")
                Label("\(crit) críticos", systemImage: "exclamationmark.triangle")
                Label("Total: \(fmt(sum))", systemImage: "archivebox")
            }
            .font(.footnote)
            .foregroundColor(.secondary)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        Button {
                            onTapSKU?(row.sku)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(color(coverageDays: row.coverageDays, leadTime: row.leadTimeDays, minGap: row.stock - row.minStock, wos: row.wos))
                                    .frame(width: 10, height: 10)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.sku)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)

                                    Text("Stock: \(fmt(row.stock)) \(row.unit)  •  Cons/sem: \(fmt(row.avgWeekly))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Text("Cobertura: \(daysText(row.coverageDays))  (\(wosText(row.wos)) sem)  •  Quiebre: \(dateText(row.depleteDate))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Text("Min: \(fmt(row.minStock))  •  ROP: \(fmt(row.reorderPoint))  •  LT: \(row.leadTimeDays)d — \(row.coversLT ? "cubre LT" : "NO cubre LT")")
                                        .font(.caption)
                                        .foregroundColor(row.coversLT ? .secondary : .red)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("WoS").font(.caption).foregroundColor(.secondary)
                                    Text(wosText(row.wos)).font(.headline.monospacedDigit())
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(UIColor.secondarySystemBackground))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 8)
        .onAppear(perform: loadItems)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("InventoryUpdated"))) { _ in
            loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ForecastRatesUpdated"))) { notif in
            if let dict = notif.userInfo?["rates"] as? [String: Double] {
                forecastRates = dict
                loadItems()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SupplyPlanUpdated"))) { _ in
            loadItems()
        }
    }

    private func loadItems() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "Item")
        req.sortDescriptors = [NSSortDescriptor(key: "sku", ascending: true)]
        do { items = try ctx.fetch(req) } catch { items = [] }
    }

    private func simulateCoverage(for sku: String, stock: Double, weekly: Double, asOf now: Date) -> (coverageDays: Double?, wos: Double?, depleteDate: Date?) {
        guard weekly > 0 else { return (nil, nil, nil) }
        var s = stock
        let immediateBO = BOStore.shared.list(for: sku).reduce(0.0) { partial, bo in
            if let due = bo.due { return (due <= now) ? partial + bo.qty : partial }
            return partial + bo.qty
        }
        s -= immediateBO
        if s <= 0 { return (0, 0, now) }

        let cal = Calendar.current
        let maxWeeks = 52
        for w in 1...maxWeeks {
            let weekStart = cal.date(byAdding: .day, value: (w-1)*7, to: now)!
            let weekEnd   = cal.date(byAdding: .day, value: w*7, to: now)!

            let incoming = POStore.shared.list(for: sku).reduce(0.0) { acc, po in
                (po.eta > weekStart && po.eta <= weekEnd) ? acc + po.qty : acc
            }
            s += incoming

            let boWeek = BOStore.shared.list(for: sku).reduce(0.0) { acc, bo in
                if let due = bo.due { return (due > weekStart && due <= weekEnd) ? acc + bo.qty : acc }
                return acc
            }
            s -= boWeek

            s -= weekly

            if s <= 0 {
                let sBefore = s + weekly
                let frac = max(0, sBefore / weekly)
                let days = Double((w-1)*7) + frac * 7.0
                let deplete = cal.date(byAdding: .day, value: Int(days.rounded(.down)), to: now)
                return (days, days/7.0, deplete)
            }
        }
        let days = Double(maxWeeks * 7)
        let deplete = Calendar.current.date(byAdding: .day, value: maxWeeks * 7, to: now)
        return (days, days/7.0, deplete)
    }

    private func fmt(_ v: Double) -> String { v == floor(v) ? "\(Int(v))" : String(format: "%.2f", v) }
    private func wosText(_ w: Double?) -> String { guard let w = w else { return "—" }; return w < 10 ? String(format: "%.2f", w) : String(format: "%.0f", w) }
    private func color(coverageDays: Double?, leadTime: Int, minGap: Double, wos: Double?) -> Color {
        if minGap < 0 { return .red }
        if leadTime > 0, let cd = coverageDays {
            if cd < Double(leadTime) { return .red }
            if cd < Double(leadTime) * 1.2 { return .orange } 
        }
        if let w = wos {
            if w < redThreshold { return .red }
            if w < amberThreshold { return .orange }
        }
        return .green
    }
    private func daysText(_ d: Double?) -> String {
        guard let d = d, d.isFinite else { return "—" }
        return String(format: "%.0f d", d)
    }
    private func dateText(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let df = DateFormatter()
        df.dateStyle = .short
        return df.string(from: date)
    }
}
struct EmptyStateOverlay: View {
    @Environment(\.managedObjectContext) private var ctx
    let onAction: (HomeView.Route) -> Void

    @State private var itemCount: Int = 0

    var body: some View {
        Group {
            if itemCount == 0 {
                VStack {
                    Spacer()
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sin SKUs todavía")
                                .font(.title3.weight(.semibold))
                            Text("Empieza agregando un SKU manualmente o importando un CSV. También puedes escanear y vincular un código.")
                                .font(.footnote)
                                .foregroundColor(.secondary)

                            HStack(spacing: 10) {
                                Button { onAction(.nuevoSKU) } label: {
                                    Label("Agregar SKU", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)

                                Button { onAction(.importar) } label: {
                                    Label("Importar", systemImage: "square.and.arrow.down.on.square")
                                }
                                .buttonStyle(.bordered)

                                Button { onAction(.escanear) } label: {
                                    Label("Escanear", systemImage: "barcode.viewfinder")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 18)
                }
                .transition(.opacity)
                .onAppear(perform: refresh)
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("InventoryUpdated"))) { _ in refresh() }
            }
        }
    }

    private func refresh() {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "Item")
        req.includesSubentities = false
        do { itemCount = try ctx.count(for: req) }
        catch { itemCount = 0 }
    }
}

struct AddSKUView: View {
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    @State private var sku: String = ""
    @State private var stockInicial: Double = 0
    @State private var unit: String = "pz"
    @State private var minStock: Double = 0
    @State private var reorderPoint: Double = 0
    @State private var leadTimeDays: Int = 0

    @State private var errorText: String? = nil

    var body: some View {
        Form {
            Section(header: Text("SKU")) {
                TextField("Ej. K11TOP", text: $sku)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section(header: Text("Inventario inicial")) {
                HStack {
                    Text("Stock")
                    Spacer()
                    TextField("0", value: $stockInicial, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }
                HStack {
                    Text("Unidad")
                    Spacer()
                    TextField("pz", text: $unit)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }
            }

            Section(header: Text("Parámetros (opcionales)")) {
                HStack {
                    Text("Mínimo")
                    Spacer()
                    TextField("0", value: $minStock, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }
                HStack {
                    Text("ROP")
                    Spacer()
                    TextField("0", value: $reorderPoint, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }
                Stepper("Lead time: \(leadTimeDays) días", value: $leadTimeDays, in: 0...365, step: 1)
            }

            if let err = errorText {
                Section { Text(err).foregroundColor(.red).font(.footnote) }
            }

            Section {
                Button { save() } label: {
                    Label("Guardar", systemImage: "checkmark.circle.fill")
                }
            }
        }
        .navigationTitle("Agregar SKU")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        let s = sku.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { errorText = "Escribe un SKU"; return }

        ctx.performAndWait {
            do {
                let fetch = NSFetchRequest<NSManagedObject>(entityName: "Item")
                fetch.predicate = NSPredicate(format: "sku == %@", s)
                fetch.fetchLimit = 1
                let existing = try ctx.fetch(fetch).first

                let item: NSManagedObject
                if let ex = existing {
                    item = ex
                } else {
                    item = NSEntityDescription.insertNewObject(forEntityName: "Item", into: ctx)
                    item.setValue(s, forKey: "sku")
                    item.setValue(true, forKey: "active")
                }

                let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
                item.setValue(u.isEmpty ? "pz" : u, forKey: "unit")
                item.setValue(minStock, forKey: "minStock")
                item.setValue(reorderPoint, forKey: "reorderPoint")
                item.setValue(Int16(leadTimeDays), forKey: "leadTimeDays")
                item.setValue(Date(), forKey: "updatedAt")

                let mv = NSEntityDescription.insertNewObject(forEntityName: "Movement", into: ctx)
                mv.setValue(UUID(), forKey: "id")
                mv.setValue(Int16(2), forKey: "type")
                mv.setValue(s, forKey: "sku")
                mv.setValue(stockInicial, forKey: "qty")
                mv.setValue("Stock inicial", forKey: "note")
                mv.setValue(Date(), forKey: "date")

                try ctx.save()
                NotificationCenter.default.post(name: Notification.Name("InventoryUpdated"), object: nil)
                dismiss()
            } catch {
                errorText = "No se pudo guardar: \(error.localizedDescription)"
            }
        }
    }
}
