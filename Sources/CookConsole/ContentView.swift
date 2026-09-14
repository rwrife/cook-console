import SwiftUI

/// Empty-library placeholder shown at launch until the recipe library
/// lands in issue #3 (M2/M3 milestones).
struct ContentView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Recipes Yet", systemImage: "fork.knife")
        } description: {
            Text("Your recipes will appear here. Recipes stay on this device — no accounts, no cloud.")
        } actions: {
            Button("Add a Recipe") {
                // Import/create UI arrives in issue #3.
            }
        }
        .navigationTitle("Cook Console")
    }
}

#Preview {
    NavigationStack {
        ContentView()
    }
}
