import Foundation
import CoreData

final class PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "Consumibles", managedObjectModel: model)

        if let d = container.persistentStoreDescriptions.first {
            d.shouldMigrateStoreAutomatically = true
            d.shouldInferMappingModelAutomatically = true
        }

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        }

        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Error cargando Core Data: \(error)")
            }
        }

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        purgeLegacySeedDataIfPresent()
    }


    private func purgeLegacySeedDataIfPresent() {
        let flagKey = "DidPurgeLegacySeedData.v1"
        let ud = UserDefaults.standard
        guard ud.bool(forKey: flagKey) == false else { return }

        let ctx = container.viewContext

        let legacySKUs = ["K00", "K01", "LBL"]
        let req = NSFetchRequest<NSManagedObject>(entityName: "Item")
        req.predicate = NSPredicate(format: "sku IN %@", legacySKUs)
        req.fetchLimit = 1

        let hasLegacy = ((try? ctx.count(for: req)) ?? 0) > 0
        guard hasLegacy else {
            ud.set(true, forKey: flagKey)
            return
        }

        ctx.performAndWait {
            ["Movement", "Item"].forEach { entity in
                let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
                let del = NSBatchDeleteRequest(fetchRequest: fetch)
                del.resultType = .resultTypeObjectIDs
                do {
                    let result = try ctx.execute(del) as? NSBatchDeleteResult
                    if let ids = result?.result as? [NSManagedObjectID], !ids.isEmpty {
                        let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: ids]
                        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [ctx])
                    }
                } catch {
                    print("Batch delete error for \(entity): \(error)")
                }
            }

            do { try ctx.save() } catch { }
        }

        ud.set(true, forKey: flagKey)
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let item = NSEntityDescription()
        item.name = "Item"
        item.managedObjectClassName = "NSManagedObject"

        let sku = NSAttributeDescription()
        sku.name = "sku"
        sku.attributeType = .stringAttributeType
        sku.isOptional = false

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = "—"
        
        let unit = NSAttributeDescription()
        unit.name = "unit"
        unit.attributeType = .stringAttributeType
        unit.isOptional = false
        unit.defaultValue = "pz"

        let category = NSAttributeDescription()
        category.name = "category"
        category.attributeType = .stringAttributeType
        category.isOptional = true

        let cost = NSAttributeDescription()
        cost.name = "cost"
        cost.attributeType = .doubleAttributeType
        cost.isOptional = false
        cost.defaultValue = 0.0

        let minStock = NSAttributeDescription()
        minStock.name = "minStock"
        minStock.attributeType = .doubleAttributeType
        minStock.isOptional = false
        minStock.defaultValue = 0.0

        let reorderPoint = NSAttributeDescription()
        reorderPoint.name = "reorderPoint"
        reorderPoint.attributeType = .doubleAttributeType
        reorderPoint.isOptional = false
        reorderPoint.defaultValue = 0.0

        let leadTimeDays = NSAttributeDescription()
        leadTimeDays.name = "leadTimeDays"
        leadTimeDays.attributeType = .integer16AttributeType
        leadTimeDays.isOptional = false
        leadTimeDays.defaultValue = 0

        let active = NSAttributeDescription()
        active.name = "active"
        active.attributeType = .booleanAttributeType
        active.isOptional = false
        active.defaultValue = true

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()

        item.properties = [sku, name, unit, category, cost, minStock, reorderPoint, leadTimeDays, active, updatedAt]

        let movement = NSEntityDescription()
        movement.name = "Movement"
        movement.managedObjectClassName = "NSManagedObject"

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false

        let mType = NSAttributeDescription()
        mType.name = "type"             
        mType.attributeType = .integer16AttributeType
        mType.isOptional = false

        let mSKU = NSAttributeDescription()
        mSKU.name = "sku"
        mSKU.attributeType = .stringAttributeType
        mSKU.isOptional = false

        let qty = NSAttributeDescription()
        qty.name = "qty"
        qty.attributeType = .doubleAttributeType
        qty.isOptional = false

        let area = NSAttributeDescription()
        area.name = "area"
        area.attributeType = .stringAttributeType
        area.isOptional = true

        let shift = NSAttributeDescription()
        shift.name = "shift"
        shift.attributeType = .stringAttributeType
        shift.isOptional = true

        let note = NSAttributeDescription()
        note.name = "note"
        note.attributeType = .stringAttributeType
        note.isOptional = true

        let ref = NSAttributeDescription()
        ref.name = "ref"
        ref.attributeType = .stringAttributeType
        ref.isOptional = true

        let date = NSAttributeDescription()
        date.name = "date"
        date.attributeType = .dateAttributeType
        date.isOptional = false
        date.defaultValue = Date()

        movement.properties = [id, mType, mSKU, qty, area, shift, note, ref, date]

        model.entities = [item, movement]
        return model
    }
}
