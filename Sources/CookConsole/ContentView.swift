import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RecipeLibraryView()
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.reconcileTimers() }
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
            set: { presented in
                guard !presented else { return }
                // SwiftUI writes false only when the alert has actually gone
                // away. Treat it as the dismissal signal: the queue advances
                // from there, never from the OK action itself, so a
                // dismissal write can never acknowledge a second timer and a
                // new alert never races the old alert's dismissal window.
                store.completionAlertDismissed()
            }
        )
    }
}

extension View {
    func timerCompletionAlert() -> some View {
        modifier(TimerCompletionAlertModifier())
    }
}
