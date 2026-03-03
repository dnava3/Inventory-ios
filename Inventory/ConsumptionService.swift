import CoreData

enum ConsumptionService {
    static func sumConsumption(for sku: String, from start: Date, to end: Date, in ctx: NSManagedObjectContext) -> Double {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "Movement")
        req.resultType = .dictionaryResultType
        req.predicate = NSPredicate(format: "sku == %@ AND type == %d AND date >= %@ AND date < %@", sku, 1, start as NSDate, end as NSDate)
        req.includesSubentities = false

        let qtyKey = NSExpression(forKeyPath: "qty")
        let sumExp = NSExpression(forFunction: "sum:", arguments: [qtyKey])

        let ed = NSExpressionDescription()
        ed.name = "sumQty"
        ed.expression = sumExp
        ed.expressionResultType = .doubleAttributeType
        req.propertiesToFetch = [ed]

        do {
            if let dict = try ctx.fetch(req).first as? [String: Any] {
                if let num = dict["sumQty"] as? NSNumber { return num.doubleValue }
                if let dbl = dict["sumQty"] as? Double { return dbl }
            }
        } catch {
            print("ConsumptionService.sumConsumption error: \(error)")
        }
        return 0
    }

    static func averageWeeklyConsumption(for sku: String, weeks: Int = 4, asOf now: Date = Date(), in ctx: NSManagedObjectContext) -> Double {
        let days = weeks * 7
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return 0 }
        let total = sumConsumption(for: sku, from: start, to: now, in: ctx)
        return total / Double(max(weeks, 1))
    }
}
