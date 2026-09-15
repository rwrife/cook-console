import SwiftUI

@main
struct CookConsoleApp: App {
    @StateObject private var store: AppStore

    init() {
        _store = StateObject(wrappedValue: AppStore.makeDefault())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
