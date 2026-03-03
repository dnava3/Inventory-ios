//
//  InventoryApp.swift
//  Inventory
//
//  Created by Damian Nava on 02/03/26.
//

import SwiftUI
import CoreData

@main
struct InventoryApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
