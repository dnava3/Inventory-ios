import SwiftUI
import CoreData

@main
struct ConsumiblesApp: App {
    let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
        }
    }
}
