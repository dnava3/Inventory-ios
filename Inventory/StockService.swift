import CoreData

enum StockService {
    static func currentStock(for sku: String, in ctx: NSManagedObjectContext) -> Double {
        let entradas = sumQty(for: sku, type: 0, in: ctx)
        let consumos = sumQty(for: sku, type: 1, in: ctx)
        let ajustes  = sumQty(for: sku, type: 2, in: ctx)
        return entradas - consumos + ajustes
    }

    private static func sumQty(for sku: String, type: Int16, in ctx: NSManagedObjectContext) -> Double {
        let req = NSFetchRequest<NSDictionary>(entityName: "Movement")
        req.resultType = .dictionaryResultType
        req.predicate = NSPredicate(format: "sku == %@ AND type == %d", sku, type)

        let keypathExp = NSExpression(forKeyPath: "qty")
        let sumExp = NSExpression(forFunction: "sum:", arguments: [keypathExp])

        let ed = NSExpressionDescription()
        ed.name = "sumQty"
        ed.expression = sumExp
        ed.expressionResultType = .doubleAttributeType
        req.propertiesToFetch = [ed]

        do {
            if let dict = try ctx.fetch(req).first, let v = dict["sumQty"] as? Double {
                return v
            }
        } catch { /* ignore for MVP */ }
        return 0
    }
}
