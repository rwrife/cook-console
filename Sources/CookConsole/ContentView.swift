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
            set: { _ in
                // Deliberately ignored. SwiftUI writes `false` to this
                // binding as part of dismissing the alert, including while
                // the OK action runs. Treating that write as a second
                // acknowledgment used to consume the next queued timer
                // before its alert was ever shown. Completion is durable:
                // only OK acknowledges it, and any undismissed completion
                // re-presents on the next reconciliation pass.
            }
        )
    }
}

extension View {
    func timerCompletionAlert() -> some View {
        modifier(TimerCompletionAlertModifier())
    }
}
