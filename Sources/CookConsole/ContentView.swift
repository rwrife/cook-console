import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RecipeLibraryView()
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.reconcileTimers() }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                store.reconcileTimers()
            }
            .timerCompletionAlert()
            .alert("Cook Console", isPresented: errorBinding) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}

private struct TimerCompletionAlertModifier: ViewModifier {
    @EnvironmentObject private var store: AppStore

    func body(content: Content) -> some View {
        content.alert("Timer Finished", isPresented: isPresented) {
            Button("OK") { store.acknowledgePresentedCompletion() }
        } message: {
            Text(store.completedTimerMessage ?? "")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { store.completedTimerMessage != nil },
            set: { if !$0 { store.acknowledgePresentedCompletion() } }
        )
    }
}

extension View {
    func timerCompletionAlert() -> some View {
        modifier(TimerCompletionAlertModifier())
    }
}
