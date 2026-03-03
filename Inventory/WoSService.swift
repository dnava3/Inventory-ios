import CoreData

enum WoSService {
    static func wos(for sku: String, in ctx: NSManagedObjectContext) -> Double? {
        let stock = StockService.currentStock(for: sku, in: ctx)
        let avg = ConsumptionService.averageWeeklyConsumption(for: sku, weeks: 4, asOf: Date(), in: ctx)
        guard avg > 0 else { return nil }
        return stock / avg
    }
}
